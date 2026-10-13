defmodule AiInPractice.Repo do
  use Ecto.Repo,
    otp_app: :ai_in_practice,
    adapter: Ecto.Adapters.SQLite3
end
