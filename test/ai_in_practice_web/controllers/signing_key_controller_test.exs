defmodule AiInPracticeWeb.SigningKeyControllerTest do
  use AiInPracticeWeb.ConnCase, async: true

  alias AiInPractice.Reports.{Payload, Signing}

  test "publishes the public keys at the well-known path", %{conn: conn} do
    conn = get(conn, Signing.well_known_path())
    body = json_response(conn, 200)

    assert body["alg"] == "Ed25519"
    assert body["format"] == Payload.format()
    assert body["attachment"] == "ai-in-practice-signed-report.json"
    assert body["signed_bytes"] =~ "canonical JSON"
    assert body["keys"] == Signing.public_keys()
    assert [%{"status" => "current", "kid" => kid}] = body["keys"]
    assert kid == Signing.keyring().current.kid
    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
  end

  test "never publishes the private key", %{conn: conn} do
    body = conn |> get(Signing.well_known_path()) |> response(200)
    private = Signing.keyring().current.private_key

    refute body =~ Base.encode64(private)
    refute body =~ Base.url_encode64(private, padding: false)
    refute body =~ "private"
  end
end
