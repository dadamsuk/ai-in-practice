defmodule AiInPractice.Eval.Harness do
  @moduledoc """
  Runs every persona `:runs` times through the real engine and summarises
  the lot (PRD §14). See `Mix.Tasks.Eval.Personas` for the command.

  All model calls, the respondent's included, go through one
  `AiInPractice.Eval.Meter`, so the caps hold for the whole run. Once a
  cap is reached the remaining runs are skipped (`failure: :budget`).
  """

  alias AiInPractice.Eval.{Consistency, Meter, Persona, Questions, Run}

  @doc """
  Runs `personas`. Options:

    * `:engine`, `:respondent`: model clients (required)
    * `:report_client`: a different client for the report call only
    * `:runs`: runs per persona (default 3)
    * `:max_calls`, `:max_cost`: the meter's caps
    * `:concurrency`: sessions at once (default 3)
    * `:on_result`: called with each run's result as it finishes
    * `:reading`, `:limits`, `:event_timeout_ms`: passed to `AiInPractice.Eval.Run`
  """
  @spec run([Persona.t()], keyword()) :: map()
  def run(personas, opts) do
    {:ok, meter} = Meter.start_link(Keyword.take(opts, [:max_calls, :max_cost]))
    runs = Keyword.get(opts, :runs, 3)
    on_result = Keyword.get(opts, :on_result, fn _ -> :ok end)
    jobs = for p <- personas, n <- 1..runs, do: {p, n}
    handler = {__MODULE__, meter}

    :telemetry.attach(
      handler,
      [:ai_in_practice, :report, :rejected],
      &__MODULE__.handle_rejection/4,
      meter
    )

    results =
      jobs
      |> Task.async_stream(&run_one(&1, meter, opts),
        max_concurrency: Keyword.get(opts, :concurrency, 3),
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, result} ->
        on_result.(result)
        result
      end)

    :telemetry.detach(handler)

    summary =
      summarise(
        personas,
        results,
        Meter.records(meter),
        Meter.totals(meter),
        Meter.rejections(meter)
      )

    Agent.stop(meter)
    summary
  end

  # Telemetry handlers are global: while two harness runs overlap (only in
  # tests), each counts the other's rejections too.
  @doc false
  def handle_rejection(_event, _measurements, %{problems: problems}, meter) do
    if Process.alive?(meter), do: Meter.note_rejection(meter, problems)
  end

  defp run_one({persona, n}, meter, opts) do
    if Meter.exhausted?(meter) do
      skipped(persona, n)
    else
      tag = {persona.id, n}

      engine =
        Meter.client(meter, Keyword.fetch!(opts, :engine),
          tag: tag,
          report_client: opts[:report_client]
        )

      respondent = Meter.client(meter, Keyword.fetch!(opts, :respondent), tag: tag)
      run_opts = Keyword.take(opts, [:reading, :limits, :event_timeout_ms])
      result = Run.run(persona, n, engine, respondent, run_opts)
      mine = Enum.filter(Meter.records(meter), &(&1.tag == tag))

      Map.merge(result, %{
        report_calls: Enum.count(mine, &(&1.purpose == :report)),
        cost: mine |> Enum.map(& &1.cost) |> Enum.sum()
      })
    end
  end

  defp skipped(persona, n) do
    %{
      persona: persona.id,
      run: n,
      outcome: :failed,
      failure: :budget,
      closed: nil,
      transcript: [],
      report: nil,
      question_ms: [],
      report_ms: nil,
      elapsed_ms: 0,
      report_calls: 0,
      cost: 0.0
    }
  end

  @doc "The summary of a set of results, with the meter's records and totals."
  @spec summarise([Persona.t()], [map()], [Meter.call_record()], map(), map()) :: map()
  def summarise(personas, results, records, totals, rejections \\ %{}) do
    by_persona = Enum.group_by(results, & &1.persona)
    summaries = Enum.map(personas, &Consistency.summarise(&1, Map.get(by_persona, &1.id, [])))
    by_id = Map.new(summaries, &{&1.persona, &1})
    completed = Enum.filter(results, &(&1.outcome == :report))

    %{
      personas: summaries,
      pairs:
        for(
          p <- personas,
          p.pair,
          # With --only, the partner may not be in this run.
          Map.has_key?(by_id, p.pair),
          p.id < p.pair or not Enum.any?(personas, &(&1.id == p.pair and &1.pair == p.id)),
          do: Consistency.compare(by_id[p.id], by_id[p.pair])
        ),
      totals:
        Map.merge(totals, %{
          runs: length(results),
          reports: length(completed),
          first_pass: Enum.count(completed, &(&1.report_calls == 1))
        }),
      latency: %{
        question_ms: results |> Enum.flat_map(& &1.question_ms) |> stats(),
        report_ms: completed |> Enum.map(& &1.report_ms) |> Enum.reject(&is_nil/1) |> stats()
      },
      cost_per_report: completed |> Enum.map(& &1.cost) |> Consistency.mean(),
      questions:
        results
        |> Enum.reject(&(&1.transcript == []))
        |> Enum.map(&Questions.measure(&1.transcript))
        |> Questions.aggregate(),
      rejections: rejections,
      calls: calls(records)
    }
  end

  defp calls(records) do
    records
    |> Enum.group_by(& &1.purpose)
    |> Map.new(fn {purpose, recs} ->
      {purpose,
       %{
         count: length(recs),
         errors: recs |> Enum.reject(&(&1.outcome == :ok)) |> Enum.frequencies_by(& &1.outcome),
         ms: recs |> Enum.map(& &1.ms) |> stats(),
         tokens: recs |> Enum.map(& &1.tokens) |> Enum.sum(),
         cost: recs |> Enum.map(& &1.cost) |> Enum.sum()
       }}
    end)
  end

  @doc "Median, 95th percentile and maximum (nearest rank), or nil for none."
  @spec stats([number()]) :: %{p50: number(), p95: number(), max: number()} | nil
  def stats([]), do: nil

  def stats(xs) do
    sorted = Enum.sort(xs)
    %{p50: percentile(sorted, 50), p95: percentile(sorted, 95), max: List.last(sorted)}
  end

  defp percentile(sorted, p) do
    index = max(ceil(p / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, index)
  end
end
