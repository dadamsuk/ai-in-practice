defmodule Mix.Tasks.Eval.Sample do
  @shortdoc "Writes a sample report from a fictional persona (costs inference)"
  @moduledoc """
  Runs one fictional persona once and writes both reports as PDFs marked as
  a sample. See `AiInPractice.Eval.SampleCLI`.

      mix eval.sample --fake                         # free dry run
      OPENROUTER_API_KEY=... mix eval.sample         # the default sample persona
      mix eval.sample eval/samples/other.yml --out ~/samples
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    case AiInPractice.Eval.SampleCLI.run(args) do
      {:ok, _paths} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
