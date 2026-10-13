defmodule AiInPracticeWeb.Plugs.SecurityHeadersTest do
  use AiInPracticeWeb.ConnCase, async: true

  alias AiInPracticeWeb.Plugs.SecurityHeaders

  defp run(opts),
    do: Plug.Test.conn(:get, "/") |> SecurityHeaders.call(SecurityHeaders.init(opts))

  test "public pages get a same-origin CSP and no referrer", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp == SecurityHeaders.csp()
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-robots-tag") == []
  end

  test "the CSP allows only this origin" do
    csp = SecurityHeaders.csp()

    for directive <- ~w(default-src script-src style-src font-src connect-src) do
      assert csp =~ "#{directive} 'self';" or csp =~ ~r/#{directive} 'self'$/
    end

    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "object-src 'none'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "unsafe-eval"
    refute csp =~ "https:"
  end

  test "private: true adds no-store and noindex for token pages and downloads" do
    conn = run(private: true)

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "without private, caching headers are left alone" do
    conn = run([])

    assert get_resp_header(conn, "cache-control") != ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == []
  end

  test "admin pages get the same CSP" do
    conn = Phoenix.ConnTest.dispatch(build_conn(), AiInPracticeWeb.AdminEndpoint, :get, "/admin")
    assert get_resp_header(conn, "content-security-policy") == [SecurityHeaders.csp()]
  end

  test "the public router has a :private pipeline that applies it" do
    conn =
      Plug.Test.conn(:get, "/")
      |> AiInPracticeWeb.Router.private([])

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end
end
