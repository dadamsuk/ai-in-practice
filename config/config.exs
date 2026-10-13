# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ai_in_practice,
  ecto_repos: [AiInPractice.Repo],
  generators: [timestamp_type: :utc_datetime],
  env: config_env(),
  # The OpenRouter model id for this release, shown in footers and reports.
  # Overridden at runtime by OPENROUTER_MODEL.
  model: "anthropic/claude-haiku-5.5",
  # The model client (AiInPractice.LLM). Tests use the fake; development can
  # with FAKE_LLM=1 (config/runtime.exs).
  llm: {AiInPractice.LLM.OpenRouter, []}

# Configure the endpoint
config :ai_in_practice, AiInPracticeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AiInPracticeWeb.ErrorHTML, json: AiInPracticeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AiInPractice.PubSub,
  live_view: [signing_salt: "jm356Mpj"]

# The admin listener (Tailscale only in production; see AiInPractice.AdminBind)
config :ai_in_practice, AiInPracticeWeb.AdminEndpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AiInPracticeWeb.ErrorHTML, json: AiInPracticeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AiInPractice.PubSub,
  live_view: [signing_salt: "Wm3xR8sL"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ai_in_practice: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  css: [
    args: ~w(css/app.css --bundle --outdir=../priv/static/assets/css --external:/fonts/*),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  # An allow-list: crash_reason and other metadata that could carry session
  # data are never printed.
  metadata: [:request_id, :assessment]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Link tokens must never reach the logs. Phoenix filters these keys (matched
# as substrings) from logged params; "url" covers LiveView join payloads,
# which carry the page URL. Request paths are redacted by
# AiInPracticeWeb.Plugs.RequestLogger.
config :phoenix, :filter_parameters, ["password", "secret", "token", "url", "redirect"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
