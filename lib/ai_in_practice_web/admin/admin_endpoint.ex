defmodule AiInPracticeWeb.AdminEndpoint do
  @moduledoc """
  The admin listener: a separate endpoint with its own router, bound to the
  Tailscale interface in production and to localhost in development.

  Admin routes exist only here, never on the public endpoint, and this
  endpoint is never routed through Cloudflare. There is no login: being
  reachable only over Tailscale is the access control (PRD §11, §13.1).
  See `AiInPractice.AdminBind` for the boot-time guard.
  """
  use Phoenix.Endpoint, otp_app: :ai_in_practice

  @session_options [
    store: :cookie,
    key: "_ai_in_practice_admin_key",
    signing_salt: "q0tXv3Zr",
    same_site: "Strict"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :ai_in_practice,
    gzip: not code_reloading?,
    only: AiInPracticeWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :admin_endpoint], log: false
  plug AiInPracticeWeb.Plugs.RequestLogger

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AiInPracticeWeb.AdminRouter
end
