defmodule Mix.Tasks.SigningKey do
  @shortdoc "Makes, shows and checks report signing keys"
  @moduledoc """
  The report signing key commands for development. See
  `AiInPractice.SigningKeyCLI`.

      mix signing_key new
      mix signing_key public
      mix signing_key verify ai-in-practice-assessor-report.pdf

  On a release, use `bin/signing_key` with the same arguments.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    case AiInPractice.SigningKeyCLI.run(args) do
      {:ok, out} -> Mix.shell().info(String.trim_trailing(out))
      {:error, message} -> Mix.raise(String.trim_trailing(message))
    end
  end
end
