defmodule Mix.Tasks.Assessment.Try do
  @shortdoc "Runs one assessment conversation in the terminal"
  @moduledoc """
  Runs one conversation with the engine in the terminal and prints the
  reports' content. See `AiInPractice.AssessmentCLI`.

      mix assessment.try finance --fake
      OPENROUTER_API_KEY=... mix assessment.try technology_product

  Nothing is saved.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    case AiInPractice.AssessmentCLI.run(args) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
