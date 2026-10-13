defmodule AiInPracticeWeb.RecruiterLiveTest do
  use AiInPracticeWeb.ConnCase

  import Phoenix.LiveViewTest
  import AiInPractice.LinksFixtures

  alias AiInPractice.Links

  setup do
    {recruiter, token} = recruiter_link_fixture(%{firm_name: "Northgate Search", quota: 2})
    %{recruiter: recruiter, token: token}
  end

  test "shows the firm and the quota", %{conn: conn, token: token} do
    {:ok, view, html} = live(conn, ~p"/r/#{token}")
    assert html =~ "Northgate Search"
    assert view |> element("#quota") |> render() =~ "0 of 2 in use, 2 left"
    assert html =~ "No links yet."
  end

  test "is private: never cached or indexed", %{conn: conn, token: token} do
    conn = get(conn, ~p"/r/#{token}")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end

  test "mints candidate links with a role group, up to the quota, then refuses",
       %{conn: conn, token: token, recruiter: recruiter} do
    {:ok, view, _} = live(conn, ~p"/r/#{token}")

    html = view |> form("#mint-form", %{role_group: "finance"}) |> render_submit()
    assert html =~ "New link for a Finance candidate"
    url = view |> element("#minted-url") |> render() |> node_text()
    assert url =~ ~r"/a/[a-z2-7]{52}$"
    token = url |> String.split("/") |> List.last()
    assert {:ok, %{role_group: :finance}} = Links.begin_session(token)

    view |> form("#mint-form", %{role_group: "people"}) |> render_submit()
    assert view |> element("#quota") |> render() =~ "2 of 2 in use, 0 left"
    assert length(Links.list_candidate_links(recruiter)) == 2

    # The button is disabled at quota; a forced submit is still refused.
    assert view |> element("#mint-form button[disabled]") |> has_element?()
    html = render_submit(view, "mint", %{role_group: "people"})
    assert html =~ "You have used all your links"
    assert length(Links.list_candidate_links(recruiter)) == 2
  end

  test "refuses a missing or unknown role group", %{conn: conn, token: token, recruiter: r} do
    {:ok, view, _} = live(conn, ~p"/r/#{token}")

    assert render_submit(view, "mint", %{role_group: ""}) =~
             "Choose the candidate&#39;s role group."

    assert render_submit(view, "mint", %{role_group: "astronaut"}) =~ "Choose the candidate"
    assert Links.list_candidate_links(r) == []
  end

  test "shows unused, started and completed", %{conn: conn, token: token, recruiter: recruiter} do
    {:ok, recruiter} = Links.set_quota(recruiter, 5)
    {unused, _} = candidate_link_fixture(recruiter, :finance)
    {started, _} = candidate_link_fixture(recruiter, :people)
    {:ok, _} = Links.mark_started(started)
    {old, _} = candidate_link_fixture(recruiter, :people)
    {:ok, old} = Links.mark_started(old)
    backdate_start(old, 2 * 60 * 60)
    {done, _} = candidate_link_fixture(recruiter, :commercial)
    {:ok, done} = Links.mark_started(done)
    {:ok, _} = Links.mark_completed(done)

    {:ok, view, _} = live(conn, ~p"/r/#{token}")

    status = fn link -> view |> element("#link-#{link.id} [data-status]") |> render() end
    assert status.(unused) =~ "unused"
    assert status.(started) =~ "started"
    assert status.(old) =~ "started"
    assert status.(done) =~ "completed"

    # Started links stop counting towards the quota.
    assert view |> element("#quota") |> render() =~ "2 of 5 in use, 3 left"

    # Only the unused link can be withdrawn.
    assert has_element?(view, "#link-#{unused.id} button", "Withdraw")
    refute has_element?(view, "#link-#{started.id} button", "Withdraw")
    refute has_element?(view, "#link-#{done.id} button", "Withdraw")
  end

  test "withdrawing an unused link frees a slot", %{conn: conn, token: token, recruiter: r} do
    {a, _} = candidate_link_fixture(r)
    candidate_link_fixture(r)
    {:ok, view, _} = live(conn, ~p"/r/#{token}")
    assert view |> element("#quota") |> render() =~ "0 left"

    html = view |> element("#link-#{a.id} button", "Withdraw") |> render_click()
    assert html =~ "Link withdrawn"
    assert view |> element("#link-#{a.id} [data-status]") |> render() =~ "withdrawn"
    assert view |> element("#quota") |> render() =~ "1 left"
  end

  test "cannot withdraw another recruiter's link", %{conn: conn, token: token} do
    {other, _} = recruiter_link_fixture(%{firm_name: "Other"})
    {theirs, _} = candidate_link_fixture(other)
    {:ok, view, _} = live(conn, ~p"/r/#{token}")

    assert render_click(view, "withdraw", %{"id" => "#{theirs.id}"}) =~
             "already been used or withdrawn"

    assert Links.get_assessment_link(theirs.id).revoked_at == nil
  end

  test "a revoked recruiter link is a polite dead end", %{conn: conn, token: token, recruiter: r} do
    {:ok, _} = Links.revoke_recruiter_link(r)
    {:ok, view, html} = live(conn, ~p"/r/#{token}")
    assert html =~ "This page has been closed"
    refute has_element?(view, "#mint-form")
    assert render_submit(view, "mint", %{role_group: "finance"}) =~ "This page has been closed"
    assert Links.list_candidate_links(r) == []
  end

  test "revoked while open: the next action shows the dead end", %{
    conn: conn,
    token: token,
    recruiter: r
  } do
    {:ok, view, _} = live(conn, ~p"/r/#{token}")
    {:ok, _} = Links.revoke_recruiter_link(r)

    assert view |> form("#mint-form", %{role_group: "finance"}) |> render_submit() =~
             "This page has been closed"

    assert Links.list_candidate_links(r) == []
  end

  test "an unknown token is a dead end", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/r/#{Links.Token.generate()}")
    assert html =~ "This link is not recognised"
  end

  @tag :privacy
  test "the recruiter's labels and stored URLs never reach the server", %{
    conn: conn,
    token: token,
    recruiter: r
  } do
    candidate_link_fixture(r)
    {:ok, view, _} = live(conn, ~p"/r/#{token}")
    view |> form("#mint-form", %{role_group: "finance"}) |> render_submit()

    doc = view |> render() |> LazyHTML.from_fragment()

    browser_only = LazyHTML.query(doc, "[phx-hook$='BrowserOnly']")
    assert Enum.count(browser_only) == 4

    for el <- browser_only do
      attrs = el |> LazyHTML.attributes() |> hd() |> Map.new()
      refute Map.has_key?(attrs, "name"), "a browser-only field has a name"
      refute Map.has_key?(attrs, "form")
      assert attrs["phx-update"] == "ignore"

      refute Enum.any?(
               Map.keys(attrs),
               &(&1 =~ ~r/^phx-(change|blur|focus|keyup|keydown|click|submit|value)/)
             )
    end

    # No label input sits inside a form.
    assert doc |> LazyHTML.query("form .label-input") |> Enum.count() == 0
    assert doc |> LazyHTML.query(".label-input") |> Enum.count() == 2

    # Only the newly minted row carries its URL, once, for the browser to keep.
    assert doc |> LazyHTML.query(".link-url[data-value]") |> Enum.count() == 1
  end

  defp node_text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
end
