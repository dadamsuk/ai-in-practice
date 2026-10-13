defmodule AiInPracticeWeb.AssessmentControllerTest do
  use AiInPracticeWeb.ConnCase

  import AiInPractice.LinksFixtures

  alias AiInPractice.Links
  alias AiInPractice.Links.{AssessmentLink, Token}
  alias AiInPractice.Repo

  test "an unused link is ready, and opening it does not use it up", %{conn: conn} do
    {link, token} = individual_link_fixture()
    conn = get(conn, ~p"/a/#{token}")
    assert html_response(conn, 200) =~ "Your link is ready"
    assert Repo.get!(AssessmentLink, link.id).status == :unused
  end

  test "is private: never cached or indexed", %{conn: conn} do
    {_, token} = individual_link_fixture()
    conn = get(conn, ~p"/a/#{token}")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "an unknown token is a 404", %{conn: conn} do
    conn = get(conn, ~p"/a/#{Token.generate()}")
    assert html_response(conn, 404) =~ "This link is not recognised"
  end

  test "a used link is gone", %{conn: conn} do
    {link, token} = individual_link_fixture()
    {:ok, _} = Links.mark_started(link, %{role_group: :people})
    assert html_response(get(conn, ~p"/a/#{token}"), 410) =~ "already been used"
  end

  test "a revoked link is gone", %{conn: conn} do
    {recruiter, _} = recruiter_link_fixture()
    {_, token} = candidate_link_fixture(recruiter)
    {:ok, _} = Links.revoke_recruiter_link(recruiter)
    assert html_response(get(conn, ~p"/a/#{token}"), 410) =~ "withdrawn"
  end
end
