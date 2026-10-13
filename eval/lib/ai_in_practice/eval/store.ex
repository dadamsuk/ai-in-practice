defmodule AiInPractice.Eval.Store do
  @moduledoc """
  Where a harness run's results go: a directory **outside the repository
  and the app** (default `~/ai-in-practice-eval/<UTC timestamp>/`).
  Evaluation transcripts are about synthetic people, but they still never
  go in the repository, the database or the logs.

      runs/<persona>-<n>.json   transcript, report (internal levels too), timings
      summary.json              the consistency summary
      summary.md                the same, to read
  """

  alias AiInPractice.Eval.Summary

  @doc """
  Makes the output directory: `dir`, or a fresh timestamped one under
  `~/ai-in-practice-eval`. Refuses one inside `repo` (default the current
  working directory, where mix runs). `home` is where the default goes.
  """
  @spec prepare(Path.t() | nil, Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def prepare(dir, repo \\ File.cwd!(), home \\ System.user_home!()) do
    dir = Path.expand(dir || default_dir(home))

    if inside?(dir, Path.expand(repo)) do
      {:error, "#{dir} is inside the repository; evaluation output must live outside it"}
    else
      case File.mkdir_p(Path.join(dir, "runs")) do
        :ok -> {:ok, dir}
        {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp default_dir(home) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join([home, "ai-in-practice-eval", stamp])
  end

  @doc false
  def inside?(dir, root), do: dir == root or String.starts_with?(dir, root <> "/")

  @doc "Writes one run's result."
  @spec write_run(Path.t(), map()) :: Path.t()
  def write_run(dir, result) do
    path = Path.join([dir, "runs", "#{result.persona}-#{result.run}.json"])
    File.write!(path, encode(result))
    path
  end

  @doc "Writes the summary as JSON and Markdown."
  @spec write_summary(Path.t(), map(), map()) :: :ok
  def write_summary(dir, summary, settings) do
    File.write!(Path.join(dir, "summary.json"), encode(Map.put(summary, :settings, settings)))
    File.write!(Path.join(dir, "summary.md"), Summary.markdown(summary, settings))
  end

  @doc "JSON for results and summaries: tuples become lists."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> plain() |> Jason.encode!(pretty: true)

  defp plain(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> plain()
  defp plain(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> plain()
  defp plain(float) when is_float(float), do: Float.round(float, 6)
  defp plain(other), do: other

  defp key(k) when is_atom(k) or is_binary(k), do: k
  defp key(k), do: inspect(k)
end
