defmodule Mix.Tasks.Reading do
  @shortdoc "Imports and lists the reading list"
  @moduledoc """
  The reading-list commands for development. See `AiInPractice.ReadingCLI`.

      mix reading import                 # the shipped AI Leaders Library
      mix reading import path/to/library.json
      mix reading list

  On a release, use `bin/reading` with the same arguments.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    case AiInPractice.ReadingCLI.run(args) do
      {:ok, out} -> Mix.shell().info(String.trim_trailing(out))
      {:error, message} -> Mix.raise(String.trim_trailing(message))
    end
  end
end
