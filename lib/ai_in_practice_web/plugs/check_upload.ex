defmodule AiInPracticeWeb.Plugs.CheckUpload do
  @moduledoc """
  A `Plug.Parsers` parser for the check page's upload (`POST /check`, #720),
  which keeps the PDF in memory (PRD §10).

  `Plug.Parsers.MULTIPART` streams every uploaded file to a temporary file
  on disk. An assessor report must never touch disk, so this parser takes
  the check page's form instead: it reads the `report` part into a binary,
  up to `limit/0` bytes, and reads any other part as an ordinary field (the
  CSRF token). Any other multipart request is passed on to `:multipart`.

  The file is never a param, so it can never be logged with the params. It
  is left in `conn.private[:check_upload]` as one of:

    * `{:ok, pdf}`;
    * `{:error, :too_large}`: over `limit/0`; the rest is read and dropped,
      so the browser still gets the page that says so;
    * `{:error, :missing}`: no file was chosen.

  A request body over `discard_limit/0` is refused outright (413), unread.
  """

  @behaviour Plug.Parsers

  alias Plug.Conn.Utils

  @limit 5_000_000
  @discard_limit 25_000_000
  @field_limit 4_096
  @read [length: 1_000_000, read_length: 1_000_000]

  @doc "The largest PDF the check page reads, in bytes."
  def limit, do: @limit

  @doc "The largest request body the check page reads at all, in bytes."
  def discard_limit, do: @discard_limit

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(
        %Plug.Conn{method: "POST", path_info: ["check"]} = conn,
        "multipart",
        "form-data",
        _,
        _
      ) do
    if declared_length(conn) > @discard_limit do
      {:error, :too_large, conn}
    else
      read_parts(Plug.Conn.read_part_headers(conn, @read), %{}, {:error, :missing}, 0)
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp declared_length(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> 0
    end
  end

  defp read_parts({:done, conn}, params, upload, _read),
    do: {:ok, params, Plug.Conn.put_private(conn, :check_upload, upload)}

  defp read_parts({:ok, headers, conn}, params, upload, read) do
    case read_part(name(headers), conn, read) do
      {:file, "report", data, size, conn} ->
        continue(conn, params, file(data, size), read + size)

      {:file, _other, _data, size, conn} ->
        continue(conn, params, upload, read + size)

      {:field, name, value, conn} ->
        continue(conn, Map.put(params, name, value), upload, read + byte_size(value))

      {:unnamed, value, conn} ->
        continue(conn, params, upload, read + byte_size(value))

      {:error, :too_large, conn} ->
        {:error, :too_large, conn}
    end
  end

  defp read_part({:file, name}, conn, read) do
    with {:ok, data, size, conn} <- read_file(Plug.Conn.read_part_body(conn, @read), [], read),
         do: {:file, name, data, size, conn}
  end

  defp read_part({:field, name}, conn, _read) do
    with {:ok, value, conn} <- read_field(Plug.Conn.read_part_body(conn, @read), ""),
         do: {:field, name, value, conn}
  end

  defp read_part(:unnamed, conn, _read) do
    with {:ok, value, conn} <- read_field(Plug.Conn.read_part_body(conn, @read), ""),
         do: {:unnamed, value, conn}
  end

  defp continue(conn, params, upload, read) do
    if read > @discard_limit,
      do: {:error, :too_large, conn},
      else: read_parts(Plug.Conn.read_part_headers(conn, @read), params, upload, read)
  end

  defp file(_data, 0), do: {:error, :missing}
  defp file(_data, size) when size > @limit, do: {:error, :too_large}
  defp file(data, _size), do: {:ok, IO.iodata_to_binary(data)}

  # Past the limit the bytes are dropped rather than kept, so the size is
  # known without holding more than `@limit` in memory.
  defp read_file(result, acc, before), do: read_file(result, acc, 0, before)

  defp read_file({:more, chunk, conn}, acc, size, before) do
    size_now = size + byte_size(chunk)

    if before + size_now > @discard_limit do
      {:error, :too_large, conn}
    else
      conn
      |> Plug.Conn.read_part_body(@read)
      |> read_file(keep(acc, chunk, size), size_now, before)
    end
  end

  defp read_file({:ok, chunk, conn}, acc, size, _before),
    do: {:ok, Enum.reverse(keep(acc, chunk, size)), size + byte_size(chunk), conn}

  defp read_file({:done, conn}, acc, size, _before), do: {:ok, Enum.reverse(acc), size, conn}

  defp keep(acc, chunk, size) do
    if size + byte_size(chunk) > @limit, do: [], else: [chunk | acc]
  end

  defp read_field({:more, chunk, conn}, acc) do
    acc = acc <> chunk

    if byte_size(acc) > @field_limit,
      do: {:error, :too_large, conn},
      else: read_field(Plug.Conn.read_part_body(conn, @read), acc)
  end

  defp read_field({:ok, chunk, conn}, acc) do
    acc = acc <> chunk
    if byte_size(acc) > @field_limit, do: {:error, :too_large, conn}, else: {:ok, acc, conn}
  end

  defp read_field({:done, conn}, acc), do: {:ok, acc, conn}

  # A part with a file name is a file, whatever its field; only `report` is
  # kept, and any other file is read and dropped. One without is an ordinary
  # field.
  defp name(headers) do
    with {_, disposition} <- List.keyfind(headers, "content-disposition", 0),
         [_, params] <- :binary.split(disposition, ";"),
         %{"name" => name} = params <- Utils.params(params) do
      if Map.has_key?(params, "filename"), do: {:file, name}, else: {:field, name}
    else
      _ -> :unnamed
    end
  end
end
