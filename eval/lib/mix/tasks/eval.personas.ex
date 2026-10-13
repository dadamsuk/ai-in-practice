defmodule Mix.Tasks.Eval.Personas do
  @shortdoc "Runs synthetic personas through the real engine (costs inference)"
  @moduledoc """
  Runs the persona evaluation harness. See `AiInPractice.Eval.CLI`.

      mix eval.personas --fake                       # free dry run
      OPENROUTER_API_KEY=... mix eval.personas --runs 3 --max-spend 2
      mix eval.personas --only finance-cfo-capable --runs 1
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    case AiInPractice.Eval.CLI.run(args) do
      {:ok, _dir, _summary} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
