defmodule AiInPractice.Links.Token do
  @moduledoc """
  Link tokens: the only credential in the app (PRD §6).

  A token is 32 random bytes (256 bits) from `:crypto.strong_rand_bytes/1`,
  encoded as lower-case base32 without padding: 52 characters of `a-z` and
  `2-7`. That is URL-safe, long enough for
  `AiInPracticeWeb.Plugs.RequestLogger` to redact it from request logs, and
  has no capitals, so it can be set in the mono type (PRD §13.2).

  Only the SHA-256 hash of a token is stored, and links are looked up by it,
  so the database alone cannot be used to open a link. The token itself is
  shown once, when the link is created.
  """

  @bytes 32

  @doc "A new random token."
  @spec generate() :: String.t()
  def generate,
    do: @bytes |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)

  @doc "The hash stored in place of the token."
  @spec hash(String.t()) :: binary()
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)
end
