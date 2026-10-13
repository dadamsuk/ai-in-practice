defmodule AiInPracticeWeb.Plugs.RequestLoggerTest do
  use AiInPracticeWeb.ConnCase

  import ExUnit.CaptureLog

  alias AiInPracticeWeb.Plugs.RequestLogger

  @token "Zk3vQ9pX2mR7tW1yB8nC4dF6"

  # Test config logs only warnings; these tests need everything, as a
  # misconfigured production logger might.
  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  describe "redact_path/1" do
    test "replaces token-like segments" do
      assert RequestLogger.redact_path("/a/#{@token}") == "/a/[redacted]"
      assert RequestLogger.redact_path("/r/#{@token}/report.pdf") == "/r/[redacted]/report.pdf"
    end

    test "leaves ordinary paths alone" do
      assert RequestLogger.redact_path("/") == "/"
      assert RequestLogger.redact_path("/admin/links") == "/admin/links"

      assert RequestLogger.redact_path("/fonts/ibm-plex-mono-latin-400-normal.woff2") ==
               "/fonts/ibm-plex-mono-latin-400-normal.woff2"
    end
  end

  @tag :privacy
  test "a request for a token URL does not log the token", %{conn: conn} do
    log =
      capture_log([level: :debug], fn ->
        conn = get(conn, "/a/#{@token}")
        assert conn.status == 404
      end)

    assert log =~ "GET /a/[redacted]"
    assert log =~ "Sent 404 for /a/[redacted]"
    refute log =~ @token
  end

  @tag :privacy
  test "a token in a query string or LiveView join payload is filtered from logged params" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "token" => @token,
        "url" => "https://ai-in-practice.dsc.net/a/#{@token}",
        "redirect" => "/a/#{@token}",
        "role" => "finance"
      })

    refute inspect(filtered) =~ @token
    assert filtered["role"] == "finance"
  end

  test "logs the method, redacted path and status", %{conn: conn} do
    log = capture_log([level: :info], fn -> get(conn, ~p"/") end)

    assert log =~ "GET /"
    assert log =~ "Sent 200 for /"
  end
end
