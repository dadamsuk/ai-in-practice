defmodule AiInPractice.Eval.CLI do
  @moduledoc """
  `mix eval.personas`: runs personas through the real engine and writes
  the results outside the repository (`AiInPractice.Eval.Store`).

      mix eval.personas [PATH...] [options]

  PATH is persona files or directories (default `eval/personas`).

    * `--runs N`: runs per persona (default 3)
    * `--only ID,ID`: just these personas
    * `--max-spend USD`: stop sending once this much is spent (default 2.00)
    * `--max-calls N`: stop sending after this many model calls (default 400)
    * `--model ID`: the engine's model (default the release's)
    * `--report-model ID`: a different model for the report call only
    * `--respondent-model ID`: the persona's model (default the engine's)
    * `--concurrency N`: sessions at once (default 3)
    * `--out DIR`: where to write (default `~/ai-in-practice-eval/<timestamp>`)
    * `--fake`: the fake engine and respondent, free

  Real runs need `OPENROUTER_API_KEY`.
  """

  alias AiInPractice.Eval.{FakeRespondent, Harness, Persona, Store}
  alias AiInPractice.LLM.{Fake, OpenRouter}

  @switches [
    runs: :integer,
    only: :string,
    max_spend: :float,
    max_calls: :integer,
    model: :string,
    report_model: :string,
    respondent_model: :string,
    concurrency: :integer,
    out: :string,
    fake: :boolean
  ]

  @doc """
  Runs the harness. Returns `{:ok, dir, summary}` or `{:error, message}`.
  `opts[:print]` receives each progress line (default `IO.puts/1`);
  `opts[:repo]` is the repository root the output must stay out of;
  `opts[:reading]` overrides the reading list (tests).
  """
  @spec run([String.t()], keyword()) :: {:ok, Path.t(), map()} | {:error, String.t()}
  def run(argv, opts \\ []) do
    print = Keyword.get(opts, :print, &IO.puts/1)

    with {:ok, flags, paths} <- parse(argv),
         {:ok, personas} <- Persona.load_all(if(paths == [], do: ["eval/personas"], else: paths)),
         {:ok, personas} <- only(personas, flags[:only]),
         {:ok, clients} <- clients(flags),
         {:ok, dir} <- Store.prepare(flags[:out], Keyword.get(opts, :repo, File.cwd!())) do
      settings = settings(flags, clients, personas)
      print.("Writing to #{dir}")

      summary =
        Harness.run(personas,
          engine: clients.engine,
          respondent: clients.respondent,
          report_client: clients.report,
          runs: settings.runs,
          max_calls: settings.max_calls,
          max_cost: settings.max_spend,
          concurrency: Keyword.get(flags, :concurrency, 3),
          event_timeout_ms: Keyword.get(opts, :event_timeout_ms, :timer.minutes(3)),
          reading: Keyword.get(opts, :reading, &AiInPractice.Reading.active_items/0),
          on_result: fn result ->
            Store.write_run(dir, result)
            print.(progress(result))
          end
        )

      Store.write_summary(dir, summary, settings)
      print.(totals(summary, dir))
      {:ok, dir, summary}
    end
  end

  defp parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {flags, paths, []} ->
        positive(flags, paths)

      {_, _, [{flag, _} | _]} ->
        {:error, "unknown or invalid option #{flag}\n\n" <> usage()}
    end
  end

  defp positive(flags, paths) do
    case Enum.find([:runs, :max_calls, :concurrency, :max_spend], &(flags[&1] && flags[&1] <= 0)) do
      nil -> {:ok, flags, paths}
      flag -> {:error, "--#{String.replace(to_string(flag), "_", "-")} must be above zero"}
    end
  end

  defp usage, do: "usage: mix eval.personas [PATH...] [--runs N] [--only ID,ID] [--fake] ..."

  defp only(personas, nil), do: {:ok, personas}

  defp only(personas, ids) do
    wanted = String.split(ids, ",", trim: true)

    case wanted -- Enum.map(personas, & &1.id) do
      [] -> {:ok, Enum.filter(personas, &(&1.id in wanted))}
      unknown -> {:error, "no persona with id #{Enum.join(unknown, ", ")}"}
    end
  end

  defp clients(flags) do
    if flags[:fake] do
      {:ok,
       %{engine: {Fake, questions: 5}, respondent: {FakeRespondent, []}, report: nil, models: %{}}}
    else
      real_clients(flags)
    end
  end

  defp real_clients(flags) do
    if Application.get_env(:ai_in_practice, :openrouter_api_key) in [nil, ""] do
      {:error, "OPENROUTER_API_KEY is not set (or use --fake)"}
    else
      model = flags[:model] || AiInPractice.Version.model()
      respondent = flags[:respondent_model] || model
      report = flags[:report_model]

      {:ok,
       %{
         engine: {OpenRouter, model: model},
         respondent: {OpenRouter, model: respondent},
         report: report && {OpenRouter, model: report},
         models: %{model: model, report_model: report || model, respondent_model: respondent}
       }}
    end
  end

  defp settings(flags, clients, personas) do
    Map.merge(
      %{
        engine: if(flags[:fake], do: "fake", else: "openrouter"),
        rubric: AiInPractice.Rubric.version(),
        personas: length(personas),
        runs: Keyword.get(flags, :runs, 3),
        max_spend: Keyword.get(flags, :max_spend, 2.0),
        max_calls: Keyword.get(flags, :max_calls, 400)
      },
      clients.models
    )
  end

  defp progress(%{outcome: :report} = r) do
    "#{r.persona} run #{r.run}: report (#{r.closed}, #{length(r.transcript)} questions, " <>
      "#{r.report_calls} report call(s), $#{money(r.cost)}, #{div(r.elapsed_ms, 1000)}s)"
  end

  defp progress(r) do
    "#{r.persona} run #{r.run}: FAILED #{r.failure} after #{length(r.transcript)} questions"
  end

  defp totals(s, dir) do
    t = s.totals

    "Done: #{t.reports}/#{t.runs} reports, #{t.calls} calls, $#{money(t.cost)}" <>
      if(t.tripped, do: " (budget cap reached)", else: "") <> ". Summary: #{dir}/summary.md"
  end

  defp money(x), do: :erlang.float_to_binary(x / 1, decimals: 4)
end
