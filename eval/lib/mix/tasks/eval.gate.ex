defmodule Mix.Tasks.Eval.Gate do
  @shortdoc "Runs the evaluation gate before a release (costs inference)"
  @moduledoc """
  Runs the gate personas once against the real model and checks the result
  against `eval/baseline.json`. See `AiInPractice.Eval.GateCLI`.

      OPENROUTER_API_KEY=... mix eval.gate
      mix eval.gate --summary ~/ai-in-practice-eval/<run>/summary.json
      mix eval.gate --write-baseline ~/ai-in-practice-eval/<run>/summary.json
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    case AiInPractice.Eval.GateCLI.run(args) do
      {:ok, lines} ->
        Enum.each(lines, fn line -> Mix.shell().info(line) end)

      {:error, lines} ->
        Enum.each(lines, fn line -> Mix.shell().error(line) end)
        exit({:shutdown, 1})
    end
  end
end
