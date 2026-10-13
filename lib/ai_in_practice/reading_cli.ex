defmodule AiInPractice.ReadingCLI do
  @moduledoc """
  The reading-list commands, for use over SSH. In development: `mix reading
  COMMAND ...`. On a release: `bin/reading COMMAND ...`, which runs `rpc/1`
  inside the running node.

      import [PATH]   load the AI Leaders Library (default: the one shipped
                      in priv/reading/library.json); see AiInPractice.Reading.Library
      list            every entry: id, active, level, title

  Importing again is safe: entries are matched by their library id, so
  their reading-list ids (which reports refer to) never change.
  """

  alias AiInPractice.Reading
  alias AiInPractice.Reading.Library

  @usage """
  usage:
    reading import [PATH]
    reading list
  """

  @doc "Runs a command. Returns `{:ok, output}` or `{:error, message}`."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(["import"]), do: import_library(Library.default_path())
  def run(["import", path]), do: import_library(path)
  def run(["list"]), do: {:ok, list(Reading.list_items())}
  def run(_), do: {:error, @usage}

  defp import_library(path) do
    case Library.load(path) do
      {:ok, s} ->
        {:ok,
         "imported #{s.total} resources: #{s.added} added, #{s.updated} updated, #{s.deactivated} made inactive\n"}

      {:error, message} ->
        {:error, message <> "\nnothing was changed\n"}
    end
  end

  defp list([]), do: "the reading list is empty\n"

  defp list(items) do
    Enum.map_join(items, "", fn item ->
      active = if item.active, do: "active  ", else: "inactive"
      levels = if item.levels == [], do: "-", else: Enum.join(item.levels, "/")

      "#{String.pad_leading(to_string(item.id), 4)}  #{active}  #{String.pad_trailing(levels, 24)}  #{item.title}\n"
    end)
  end

  @doc """
  The release entry point, called by `bin/reading` through `rpc`. Each
  argument arrives base64-encoded so that no quoting can break out of the
  expression.
  """
  @spec rpc(String.t()) :: :ok
  def rpc(encoded) do
    args = encoded |> String.split(" ", trim: true) |> Enum.map(&Base.decode64!/1)

    case run(args) do
      {:ok, out} -> IO.write(out)
      {:error, message} -> IO.write("error: " <> message)
    end
  end
end
