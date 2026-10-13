defmodule AiInPracticeWeb.SessionControllerTest do
  # Not async: the sessions under test run in the shared supervisor.
  use AiInPracticeWeb.ConnCase, async: false

  import AiInPractice.SessionHelpers

  alias AiInPractice.Assessment.Session
  alias AiInPractice.LLMScript

  test "ending a session stops it, with no CSRF token needed", %{conn: conn} do
    {id, _} = start!([LLMScript.turn("Q1")])
    assert_event(id, {:question, _})

    conn = post(conn, ~p"/sessions/#{id}/end")
    assert response(conn, 204) == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert gone?(id)
  end

  test "an unknown or already ended session gets the same answer", %{conn: conn} do
    assert conn |> post(~p"/sessions/AAAAAAAAAAAAAAAAAAAAAAAA/end") |> response(204)
  end

  test "only POST ends a session", %{conn: conn} do
    {id, _} = start!([LLMScript.turn("Q1")])
    assert_event(id, {:question, _})

    assert get(conn, ~p"/sessions/#{id}/end").status == 404
    assert Session.whereis(id)
  end
end
