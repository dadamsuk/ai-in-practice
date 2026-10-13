defmodule AiInPracticeWeb.SigningKeyController do
  @moduledoc """
  Publishes the public keys that sign assessor reports, at
  `/.well-known/ai-in-practice/signing-keys.json` (#707): the current key
  and any retired ones, so reports signed before a rotation still verify.
  """
  use AiInPracticeWeb, :controller

  alias AiInPractice.Reports.{Payload, Signing}

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(%{
      "alg" => "Ed25519",
      "format" => Payload.format(),
      "attachment" => Signing.attachment_name(),
      "signed_bytes" =>
        "the payload as canonical JSON: keys sorted by UTF-8 bytes at every depth, no whitespace, no floats",
      "keys" => Signing.public_keys()
    })
  end
end
