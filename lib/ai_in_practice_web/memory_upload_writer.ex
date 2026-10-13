defmodule AiInPracticeWeb.MemoryUploadWriter do
  @moduledoc """
  A LiveView upload writer that keeps the upload in memory (PRD §10).

  LiveView's default writer puts every upload in a temporary file. A
  spoken answer must never touch disk, so this one collects the chunks in
  the upload channel's process and hands the whole recording to the
  LiveView as `%{audio: binary}` when it is consumed. The channel process
  ends with the upload, and the recording with it.

  `:max_bytes` caps what it will hold, in case a client ignores the
  upload's `max_file_size`.
  """

  @behaviour Phoenix.LiveView.UploadWriter

  @impl true
  def init(opts), do: {:ok, %{chunks: [], size: 0, max: Keyword.fetch!(opts, :max_bytes)}}

  @impl true
  def meta(state), do: %{audio: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  @impl true
  def write_chunk(data, %{size: size, max: max} = state) when size + byte_size(data) > max,
    do: {:error, :too_large, %{state | chunks: []}}

  def write_chunk(data, state),
    do: {:ok, %{state | chunks: [data | state.chunks], size: state.size + byte_size(data)}}

  @impl true
  def close(state, :done), do: {:ok, state}
  def close(state, _reason), do: {:ok, %{state | chunks: [], size: 0}}
end
