defmodule AiInPractice.SmokeScriptTest do
  # script/smoke is the post-deploy check. These tests serve the real public
  # endpoint over HTTP and run the script against it, then against copies
  # broken in the ways a bad deploy or a Cloudflare setting would break them.
  use ExUnit.Case, async: false

  # The refused-origin check makes Phoenix log an error; keep it out of the run.
  @moduletag :capture_log

  alias Ecto.Adapters.SQL.Sandbox

  @script Path.expand("../../script/smoke", __DIR__)
  @sha "0123456789abcdef0123456789abcdef01234567"

  defmodule Broken do
    @moduledoc false
    # The public endpoint with one thing wrong, as named by the option.
    import Plug.Conn

    def init(mode), do: mode

    def call(%{path_info: ["live", "websocket"]} = conn, :no_websocket),
      do: conn |> send_resp(404, "") |> halt()

    def call(conn, mode) do
      conn
      |> register_before_send(&break(&1, mode))
      |> AiInPracticeWeb.Endpoint.call([])
    end

    defp break(conn, :cacheable),
      do: put_resp_header(conn, "cache-control", "public, max-age=600")

    defp break(conn, :no_csp), do: delete_resp_header(conn, "content-security-policy")

    defp break(%{resp_body: body} = conn, :beacon) when body != nil do
      beacon =
        ~s(<script defer src="https://static.cloudflareinsights.com/beacon.min.js"></script>)

      %{
        conn
        | resp_body: String.replace(IO.iodata_to_binary(body), "</body>", beacon <> "</body>")
      }
    end

    defp break(%{resp_body: body} = conn, :rocket_loader) when body != nil do
      body =
        String.replace(
          IO.iodata_to_binary(body),
          ~s(type="text/javascript"),
          ~s(type="abc123-text/javascript")
        )

      %{conn | resp_body: body}
    end

    defp break(conn, _mode), do: conn
  end

  setup do
    pid = Sandbox.start_owner!(AiInPractice.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    Application.put_env(:ai_in_practice, :code_version, @sha)
    on_exit(fn -> Application.delete_env(:ai_in_practice, :code_version) end)
    :ok
  end

  defp serve(plug) do
    pid =
      start_supervised!(
        {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://localhost:#{port}"
  end

  # A loopback port with nothing listening on it.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: :loopback)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp smoke(args) do
    System.cmd(@script, args, stderr_to_stdout: true, env: [{"SMOKE_WS_WAIT", "1"}])
  end

  test "passes against a correctly configured site" do
    base = serve(AiInPracticeWeb.Endpoint)
    admin = "http://127.0.0.1:#{closed_port()}/admin"

    {out, status} = smoke([base, @sha, admin])

    assert status == 0, out
    assert out =~ "ok    footer shows code 0123456789ab"
    assert out =~ "ok    assessment is no-store"
    assert out =~ "ok    download is noindex"
    assert out =~ "ok    LiveView websocket handshake"
    assert out =~ "ok    websocket from another origin refused (403)"
    assert out =~ "ok    /admin is 404 on the public site"
    assert out =~ "ok    admin unreachable at #{admin}"
    assert out =~ "all checks passed"
  end

  test "fails when the footer shows another version" do
    {out, 1} = smoke([serve(AiInPracticeWeb.Endpoint), "fedcba9876543210"])
    assert out =~ "FAIL  footer does not show code fedcba987654 (it shows: code 0123456789ab)"
    assert out =~ "1 check(s) failed"
  end

  test "fails when private pages may be cached" do
    {out, 1} = smoke([serve({Broken, :cacheable}), @sha])
    assert out =~ "FAIL  assessment Cache-Control is 'public, max-age=600'"
    assert out =~ "FAIL  recruiter Cache-Control"
    assert out =~ "FAIL  download Cache-Control"
  end

  test "fails without a CSP" do
    {out, 1} = smoke([serve({Broken, :no_csp}), @sha])
    assert out =~ "FAIL  home has no same-origin CSP"
    assert out =~ "FAIL  assessment has no same-origin CSP"
  end

  test "fails when Cloudflare injects its beacon" do
    {out, 1} = smoke([serve({Broken, :beacon}), @sha])
    assert out =~ "FAIL  home has a Cloudflare-injected script or rewrite"
  end

  test "fails when Rocket Loader rewrites the app's script" do
    {out, 1} = smoke([serve({Broken, :rocket_loader}), @sha])
    assert out =~ "FAIL  home has a Cloudflare-injected script or rewrite"
  end

  test "fails when the websocket handshake does not upgrade" do
    {out, 1} = smoke([serve({Broken, :no_websocket}), @sha])
    assert out =~ "FAIL  LiveView websocket handshake is 404, not 101"
  end

  test "fails when the admin listener answers" do
    admin = serve(AiInPracticeWeb.AdminEndpoint) <> "/admin"
    {out, 1} = smoke([serve(AiInPracticeWeb.Endpoint), @sha, admin])
    assert out =~ "FAIL  admin answered 200 at #{admin}"
  end

  test "prints usage without a URL and SHA" do
    {out, 64} = smoke([])
    assert out =~ "script/smoke BASE_URL SHA [ADMIN_URL...]"
  end
end
