defmodule AiInPracticeWeb.Plugs.RequestLogger do
  @moduledoc """
  Logs each request with any token redacted from the path.

  Link tokens travel in the URL path, so Phoenix's own request log line
  (`GET /path`) would write them to the logs. The endpoints turn that line
  off (`Plug.Telemetry, log: false`) and use this plug instead. Any path
  segment that looks like a token (16 or more URL-safe characters) is
  replaced with `[redacted]`.
  """

  @behaviour Plug

  require Logger

  @token_segment ~r/\A[A-Za-z0-9_-]{16,}\z/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start = System.monotonic_time()
    path = redact_path(conn.request_path)
    Logger.info(fn -> [conn.method, ?\s, path] end)

    Plug.Conn.register_before_send(conn, fn conn ->
      Logger.info(fn ->
        elapsed = System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)
        ["Sent ", Integer.to_string(conn.status || 0), " for ", path, " in ", format_us(elapsed)]
      end)

      conn
    end)
  end

  @doc "Replaces every token-like segment in a request path with `[redacted]`."
  @spec redact_path(String.t()) :: String.t()
  def redact_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment ->
      if Regex.match?(@token_segment, segment), do: "[redacted]", else: segment
    end)
  end

  defp format_us(us) when us >= 1000, do: [Integer.to_string(div(us, 1000)), "ms"]
  defp format_us(us), do: [Integer.to_string(us), "µs"]
end
