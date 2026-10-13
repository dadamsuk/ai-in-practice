defmodule AiInPracticeWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Security and caching headers (PRD §10, §13.1).

  Every browser response gets `Referrer-Policy: no-referrer`; the routers
  pass `csp/0`, a strict same-origin Content Security Policy, to
  `put_secure_browser_headers`. Pass `private: true` for assessment
  pages, report downloads and anything else whose URL carries a token: those
  also get `Cache-Control: no-store` and `X-Robots-Tag: noindex`, so neither
  Cloudflare nor the browser keeps a copy and search engines never list them.
  """

  @behaviour Plug

  import Plug.Conn

  @csp Enum.join(
         [
           "default-src 'self'",
           "script-src 'self'",
           "style-src 'self'",
           "font-src 'self'",
           "img-src 'self' data:",
           "connect-src 'self'",
           "object-src 'none'",
           "base-uri 'self'",
           "form-action 'self'",
           "frame-ancestors 'none'"
         ],
         "; "
       )

  @doc "The Content-Security-Policy header value."
  @spec csp() :: String.t()
  def csp, do: @csp

  @impl true
  def init(opts), do: Keyword.get(opts, :private, false)

  @impl true
  def call(conn, private?) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_private_headers(private?)
  end

  defp put_private_headers(conn, false), do: conn

  defp put_private_headers(conn, true) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end
end
