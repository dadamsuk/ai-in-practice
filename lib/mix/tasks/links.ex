defmodule Mix.Tasks.Links do
  @shortdoc "Issues, adjusts, revokes and reports on links"
  @moduledoc """
  The admin link commands for development. See `AiInPractice.LinksCLI`.

      mix links recruiter --firm "Northgate Search" --contact "Sam" --email sam@example.com
      mix links individual --label IND-014
      mix links quota 3 15
      mix links revoke recruiter 3
      mix links revoke link 12
      mix links usage

  On a release, use `bin/links` with the same arguments.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    case AiInPractice.LinksCLI.run(args) do
      {:ok, out} -> Mix.shell().info(String.trim_trailing(out))
      {:error, message} -> Mix.raise(String.trim_trailing(message))
    end
  end
end
