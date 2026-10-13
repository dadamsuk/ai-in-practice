import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ai_in_practice start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ai_in_practice, AiInPracticeWeb.Endpoint, server: true
  config :ai_in_practice, AiInPracticeWeb.AdminEndpoint, server: true
end

if model = System.get_env("OPENROUTER_MODEL") do
  config :ai_in_practice, model: model
end

if api_key = System.get_env("OPENROUTER_API_KEY") do
  config :ai_in_practice, openrouter_api_key: api_key
end

# The assessor report signing key (AiInPractice.Reports.Signing): a Base64
# Ed25519 seed, and the public keys of retired ones, comma-separated. In
# production the application refuses to boot without a key; elsewhere an
# ephemeral key is made at boot.
if signing_key = System.get_env("REPORT_SIGNING_KEY") do
  config :ai_in_practice, :report_signing,
    private_key: signing_key,
    retired: System.get_env("REPORT_SIGNING_RETIRED_KEYS")
end

# The fake model, for walking the journey without spending. Dev only.
if config_env() == :dev do
  fake_mode = System.get_env("FAKE_LLM")

  if opts = fake_mode && AiInPractice.LLM.Fake.modes()[fake_mode] do
    config :ai_in_practice, llm: {AiInPractice.LLM.Fake, opts}
  end

  if fake_mode == "short" do
    config :ai_in_practice, assessment_limits: %{hard_stop_ms: :timer.minutes(1)}
  end
end

parse_ip = fn name, value ->
  case :inet.parse_strict_address(String.to_charlist(value)) do
    {:ok, ip} -> ip
    {:error, _} -> raise "#{name} is not an IP address: #{inspect(value)}"
  end
end

if config_env() == :dev do
  if admin_ip = System.get_env("ADMIN_IP") do
    config :ai_in_practice, AiInPracticeWeb.AdminEndpoint,
      http: [ip: parse_ip.("ADMIN_IP", admin_ip), port: 4101]
  end
end

# Dev uses 4100/4101 because 4000 is taken on the dev machine (dedev).
default_port = if config_env() == :dev, do: "4100", else: "4000"

config :ai_in_practice, AiInPracticeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", default_port))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :ai_in_practice, AiInPracticeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/ai_in_practice_web/router\.ex$"E,
        ~r"lib/ai_in_practice_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/ai_in_practice/ai_in_practice.db
      """

  config :ai_in_practice, AiInPractice.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # The public host name, e.g. ai-in-practice.dsc.net. Cloudflare terminates
  # TLS in front of it, so generated URLs are https on port 443. LiveView's
  # default check_origin accepts websockets only from this url host.
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public host name, e.g. ai-in-practice.dsc.net.
      """

  # The model key. Without it no conversation can start, so a release
  # without one refuses to boot rather than failing on the first visitor.
  System.get_env("OPENROUTER_API_KEY") ||
    raise """
    environment variable OPENROUTER_API_KEY is missing.
    Set it to the OpenRouter key (zero data retention, with a spend cap).
    """

  # The public listener's bind address. Behind a Cloudflare Tunnel on the
  # same host this is 127.0.0.1, so nothing but the tunnel can reach it.
  public_ip = parse_ip.("PUBLIC_IP", System.get_env("PUBLIC_IP") || "::")

  config :ai_in_practice, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The admin listener binds to this host's Tailscale address and nothing
  # else. The application refuses to boot without it (AiInPractice.AdminBind).
  admin_ip =
    System.get_env("ADMIN_IP") ||
      raise """
      environment variable ADMIN_IP is missing.
      Set it to this host's Tailscale address, e.g. 100.x.y.z.
      """

  admin_port = String.to_integer(System.get_env("ADMIN_PORT") || "4001")

  config :ai_in_practice, AiInPracticeWeb.AdminEndpoint,
    url: [host: System.get_env("ADMIN_HOST") || admin_ip, port: admin_port, scheme: "http"],
    http: [ip: parse_ip.("ADMIN_IP", admin_ip), port: admin_port],
    secret_key_base: secret_key_base

  config :ai_in_practice, AiInPracticeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: public_ip],
    secret_key_base: secret_key_base
end
