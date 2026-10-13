defmodule AiInPracticeWeb.AdminEndpointTest do
  use AiInPracticeWeb.ConnCase

  alias AiInPracticeWeb.{AdminEndpoint, AdminRouter, Endpoint, Router}

  defp admin_get(conn, path), do: Phoenix.ConnTest.dispatch(conn, AdminEndpoint, :get, path, nil)
  defp public_get(conn, path), do: Phoenix.ConnTest.dispatch(conn, Endpoint, :get, path, nil)

  defp admin_paths do
    for %{path: path} <- Phoenix.Router.routes(AdminRouter), uniq: true do
      String.replace(path, ~r/:[a-z_]+/, "x")
    end
  end

  test "admin routes respond on the admin endpoint", %{conn: conn} do
    html = conn |> admin_get("/admin") |> html_response(200)
    assert html =~ "Admin"
    assert html =~ ~s(class="running-foot mono")
  end

  test "admin pages are never cached or indexed", %{conn: conn} do
    conn = admin_get(conn, "/admin")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "every admin route is a 404 on the public endpoint", %{conn: conn} do
    assert admin_paths() != []

    for path <- admin_paths() do
      assert public_get(conn, path).status == 404, "#{path} answered on the public endpoint"
    end
  end

  test "the public router defines nothing under /admin and no admin controllers" do
    for %{path: path, plug: plug} <- Phoenix.Router.routes(Router) do
      refute String.starts_with?(path, "/admin")
      refute plug |> Module.split() |> Enum.member?("Admin")
    end
  end

  test "the public home page is not served by the admin endpoint", %{conn: conn} do
    assert admin_get(conn, "/").status == 404
  end
end
