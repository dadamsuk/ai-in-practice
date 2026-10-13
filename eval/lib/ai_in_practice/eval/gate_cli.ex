defmodule AiInPractice.Eval.GateCLI do
  @moduledoc """
  `mix eval.gate`: the evaluation gate before a release (#730).

      mix eval.gate [--out DIR]                 # run the gate personas once, then check
      mix eval.gate --summary FILE              # check a summary.json already written
      mix eval.gate --write-baseline FILE       # set the baseline from a summary.json

  `--baseline FILE` (default `eval/baseline.json`) names the personas, the
  levels to compare against and the thresholds; see
  `AiInPractice.Eval.Gate`. `--max-spend USD` caps the run (default 1.00).
  The run needs `OPENROUTER_API_KEY` and costs real inference.
  """

  alias AiInPractice.Eval.{CLI, Gate, Store}

  @switches [
    baseline: :string,
    summary: :string,
    out: :string,
    write_baseline: :string,
    max_spend: :float
  ]

  @doc """
  Returns `{:ok, lines}` when the gate passes (or a baseline was written)
  and `{:error, lines}` when it fails. `opts` are passed to
  `AiInPractice.Eval.CLI.run/2` for the run (tests).
  """
  @spec run([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def run(argv, opts \\ []) do
    case OptionParser.parse(argv, strict: @switches) do
      {flags, [], []} ->
        dispatch(flags, Keyword.get(flags, :baseline, "eval/baseline.json"), opts)

      _ ->
        {:error,
         [
           "usage: mix eval.gate [--out DIR | --summary FILE | --write-baseline FILE] [--baseline FILE]"
         ]}
    end
  end

  defp dispatch(flags, baseline_path, opts) do
    cond do
      flags[:write_baseline] -> write_baseline(flags[:write_baseline], baseline_path)
      flags[:summary] -> with_baseline(baseline_path, &check(read_json(flags[:summary]), &1))
      true -> with_baseline(baseline_path, &run_gate(&1, flags, opts))
    end
  end

  defp with_baseline(path, fun) do
    case read_json(path) do
      {:ok, baseline} -> fun.(baseline)
      {:error, message} -> {:error, [message]}
    end
  end

  defp run_gate(baseline, flags, opts) do
    argv =
      ["--only", Enum.join(Gate.personas(baseline), ","), "--runs", "1"] ++
        ["--max-spend", to_string(Keyword.get(flags, :max_spend, 1.0))] ++
        if(flags[:out], do: ["--out", flags[:out]], else: []) ++
        Keyword.get(opts, :extra_args, [])

    case CLI.run(argv, opts) do
      {:ok, dir, _summary} -> check(read_json(Path.join(dir, "summary.json")), baseline)
      {:error, message} -> {:error, [message]}
    end
  end

  defp check({:ok, summary}, baseline) do
    case Gate.check(summary, baseline) do
      {:ok, notes} -> {:ok, ["Gate passed." | notes]}
      {:error, failures} -> {:error, ["Gate failed:" | Enum.map(failures, &("- " <> &1))]}
    end
  end

  defp check({:error, message}, _baseline), do: {:error, [message]}

  defp write_baseline(summary_path, baseline_path) do
    with {:ok, summary} <- read_json(summary_path) do
      thresholds =
        case read_json(baseline_path) do
          {:ok, old} -> Map.get(old, "thresholds", %{})
          _ -> %{}
        end

      File.write!(baseline_path, Store.encode(Gate.baseline(summary, thresholds)) <> "\n")

      {:ok,
       [
         "Baseline written to #{baseline_path} (#{map_size(summary["personas"] |> Map.new(&{&1["persona"], &1}))} personas)."
       ]}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  defp read_json(path) do
    with {:ok, text} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      {:ok, map}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "#{path}: not valid JSON"}
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      _ -> {:error, "#{path}: expected a JSON object"}
    end
  end
end
