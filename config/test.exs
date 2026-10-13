import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ai_in_practice, AiInPractice.Repo,
  database: Path.expand("../ai_in_practice_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ai_in_practice, AiInPracticeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "20bTfx+ZUm/BX2+V5JAYVJQOr16mdGIUPRcjPntmJDeH2RXLucboIpG3B+k26bvN",
  server: false

config :ai_in_practice, AiInPracticeWeb.AdminEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "4m8Qb2Vx6Zr0Lp3Nw7Ks1Hd5Fj9Tg2Yc6Ue0Io4Pa8Sd2Fg6Hj0Kl4Zx8Cv2Bn6M",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The fake model, no retry delays, and OpenRouter requests answered by
# Req.Test stubs, never the network.
config :ai_in_practice,
  llm: {AiInPractice.LLM.Fake, []},
  llm_backoff_ms: [0, 0],
  llm_rate_limit_backoff_ms: [0, 0, 0],
  # Sessions stop as soon as their owner exits; tests that reconnect set
  # :reattach_ms themselves.
  assessment_limits: %{reattach_ms: 0},
  openrouter_api_key: "test-key",
  openrouter_req_options: [plug: {Req.Test, AiInPractice.LLM.OpenRouter}],
  # The fake transcriber; the engine's client is answered by Req.Test stubs.
  transcriber: {AiInPractice.Transcriber.Fake, []},
  transcriber_req_options: [plug: {Req.Test, AiInPractice.Transcriber.Manuel}]
