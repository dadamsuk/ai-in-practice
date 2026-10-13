defmodule AiInPracticeWeb.PageControllerTest do
  use AiInPracticeWeb.ConnCase

  test "GET / renders the public home page in the frame", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "<title"
    assert html =~ "AI in Practice"
    assert html =~ ~s(class="running-head")
    assert html =~ "Access is by personal link only"
    refute html =~ "Phoenix Framework"
  end

  test "the footer shows code, rubric and model versions in mono", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    [footer] = Regex.run(~r/<footer[^>]*id="running-foot".*?<\/footer>/s, html)

    assert footer =~ ~s(class="running-foot mono")
    assert footer =~ "code #{AiInPractice.Version.code_version()}"
    assert footer =~ "rubric v#{AiInPractice.Version.rubric_version()}"
    assert footer =~ "model #{AiInPractice.Version.model()}"
  end

  test "the footer shows a baked-in SHA when one is set", %{conn: conn} do
    Application.put_env(:ai_in_practice, :code_version, "0123456789ABCDEF")
    on_exit(fn -> Application.delete_env(:ai_in_practice, :code_version) end)

    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "code 0123456789ab"
  end

  test "an unknown path is a 404", %{conn: conn} do
    conn = get(conn, "/no-such-page")
    assert conn.status == 404
  end
end
