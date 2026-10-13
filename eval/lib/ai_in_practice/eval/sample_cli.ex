defmodule AiInPractice.Eval.SampleCLI do
  @moduledoc """
  `mix eval.sample`: one fictional persona through the real engine, once,
  and both reports as PDFs marked as a sample (#724), for showing what a
  report looks like (the LinkedIn post, PRD §17).

      mix eval.sample [PERSONA_FILE] [options]

  PERSONA_FILE defaults to `eval/samples/sample-operations-director.yml`.
  The file must hold exactly one persona, and it must be made up.

    * `--out DIR`: where to write (default `~/ai-in-practice-eval/<timestamp>`)
    * `--max-spend USD`: stop sending once this much is spent (default 0.50)
    * `--model ID`, `--report-model ID`, `--respondent-model ID`: as `mix eval.personas`
    * `--fake`: the fake engine and respondent, free

  Writes `sample-assessor-report.pdf`, `sample-your-report.pdf` and the run's
  JSON (`runs/`) outside the repository. Both PDFs say "sample" in their
  header and on every page, and the assessor report's signed content says so
  too, so the check page shows it. The assessor PDF is signed with the
  configured key (in development, a throwaway one).

  Real runs need `OPENROUTER_API_KEY`.
  """

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Eval.{CLI, Harness, Persona, Store}
  alias AiInPractice.Reports.PDF

  @default "eval/samples/sample-operations-director.yml"

  @switches [
    out: :string,
    max_spend: :float,
    model: :string,
    report_model: :string,
    respondent_model: :string,
    fake: :boolean
  ]

  @doc """
  Makes the sample. Returns `{:ok, [path]}` (the files written) or
  `{:error, message}`. `opts[:print]` receives progress lines (default
  `IO.puts/1`); `opts[:repo]` is the repository root the output must stay
  out of; `opts[:reading]` overrides the reading list and `opts[:date]` the
  report's date (tests).
  """
  @spec run([String.t()], keyword()) :: {:ok, [Path.t()]} | {:error, String.t()}
  def run(argv, opts \\ []) do
    print = Keyword.get(opts, :print, &IO.puts/1)

    with {:ok, flags, path} <- parse(argv),
         {:ok, persona} <- load(path),
         {:ok, clients} <- CLI.clients(flags),
         {:ok, dir} <- Store.prepare(flags[:out], Keyword.get(opts, :repo, File.cwd!())) do
      print.("Writing to #{dir}")
      parent = self()

      Harness.run([persona],
        engine: clients.engine,
        respondent: clients.respondent,
        report_client: clients.report,
        runs: 1,
        concurrency: 1,
        max_cost: Keyword.get(flags, :max_spend, 0.5),
        event_timeout_ms: Keyword.get(opts, :event_timeout_ms, :timer.minutes(3)),
        reading: Keyword.get(opts, :reading, &AiInPractice.Reading.active_items/0),
        on_result: &send(parent, {__MODULE__, &1})
      )

      receive do
        {__MODULE__, result} -> finish(result, persona, dir, opts, print)
      end
    end
  end

  defp parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {flags, [], []} -> positive(flags, @default)
      {flags, [path], []} -> positive(flags, path)
      {_, [_, _ | _], []} -> {:error, "give one persona file at most\n\n" <> usage()}
      {_, _, [{flag, _} | _]} -> {:error, "unknown or invalid option #{flag}\n\n" <> usage()}
    end
  end

  defp positive(flags, path) do
    if flags[:max_spend] && flags[:max_spend] <= 0,
      do: {:error, "--max-spend must be above zero"},
      else: {:ok, flags, path}
  end

  defp usage, do: "usage: mix eval.sample [PERSONA_FILE] [--out DIR] [--max-spend USD] [--fake]"

  defp load(path) do
    if File.regular?(path) do
      case Persona.load_all([path]) do
        {:ok, [persona]} -> {:ok, persona}
        {:error, message} -> {:error, message}
      end
    else
      {:error, "#{path} is not a persona file"}
    end
  end

  defp finish(%{outcome: :report, report: report} = result, persona, dir, opts, print) do
    Store.write_run(dir, result)

    meta = %{
      role_group: persona.role_group,
      date: Keyword.get_lazy(opts, :date, &Date.utc_today/0),
      mode: :text,
      link_kind: :individual,
      sample: true
    }

    report = struct!(Report, Map.delete(report, :manipulation_note))

    paths =
      for {audience, name} <- [
            assessor: "sample-assessor-report.pdf",
            candidate: "sample-your-report.pdf"
          ] do
        path = Path.join(dir, name)
        File.write!(path, PDF.render(audience, report, meta))
        path
      end

    print.("Sample written, $#{:erlang.float_to_binary(result.cost / 1, decimals: 4)}:")
    Enum.each(paths, &print.("  #{&1}"))
    {:ok, paths}
  end

  defp finish(result, _persona, dir, _opts, _print) do
    Store.write_run(dir, result)
    {:error, "the sample run failed (#{result.failure}); its transcript is in #{dir}/runs"}
  end
end
