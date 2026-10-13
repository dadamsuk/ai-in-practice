defmodule AiInPracticeWeb.Plugs.UsableLinkTest do
  use AiInPracticeWeb.ConnCase

  import AiInPractice.LinksFixtures

  alias AiInPractice.Links
  alias AiInPractice.Links.{AssessmentLink, Token}
  alias AiInPractice.Repo

  # Everything that varies per request, so two dead ends can be compared.
  defp page(conn) do
    conn
    |> html_response(404)
    |> String.replace(~r/<meta name="csrf-token" content="[^"]+"/, "")
  end

  test "an unused link opens the start screen and is not used up", %{conn: conn} do
    {link, token} = individual_link_fixture()
    html = conn |> get(~p"/a/#{token}") |> html_response(200)
    assert html =~ "Begin the conversation"
    assert Repo.get!(AssessmentLink, link.id).status == :unused
  end

  test "is private: never cached or indexed, the dead end included", %{conn: conn} do
    {_, token} = individual_link_fixture()

    for path <- [~p"/a/#{token}", ~p"/a/#{Token.generate()}"] do
      conn = get(build_conn(), path)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    assert conn
  end

  test "unknown, withdrawn, used and completed links get one identical 404 dead end", %{
    conn: conn
  } do
    {recruiter, _} = recruiter_link_fixture()
    {_, revoked} = candidate_link_fixture(recruiter)
    {:ok, _} = Links.revoke_recruiter_link(recruiter)

    {withdrawn_link, withdrawn} = individual_link_fixture("IND-W")
    {:ok, _} = Links.revoke_assessment_link(withdrawn_link)

    {used_link, used} = individual_link_fixture("IND-U")
    {:ok, _} = Links.mark_started(used_link, %{role_group: :people})

    {done_link, done} = individual_link_fixture("IND-D")
    {:ok, started} = Links.mark_started(done_link, %{role_group: :people})
    {:ok, _} = Links.mark_completed(started)

    unknown = page(get(conn, ~p"/a/#{Token.generate()}"))
    assert unknown =~ "This link cannot be opened"
    assert unknown =~ "ask the person who sent it to you for a new one"

    for token <- [revoked, withdrawn, used, done] do
      assert page(get(build_conn(), ~p"/a/#{token}")) == unknown
    end
  end
end
