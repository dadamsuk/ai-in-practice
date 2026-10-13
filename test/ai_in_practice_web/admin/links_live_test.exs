defmodule AiInPracticeWeb.Admin.LinksLiveTest do
  use AiInPracticeWeb.ConnCase

  import Phoenix.LiveViewTest
  import AiInPractice.LinksFixtures

  alias AiInPractice.Links

  @endpoint AiInPracticeWeb.AdminEndpoint

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  test "issues a recruiter link and shows its URL once", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin")

    html =
      view
      |> form("#recruiter-form",
        recruiter: %{
          firm_name: "Northgate Search",
          contact_name: "Sam",
          contact_email: "sam@northgate.example",
          quota: "12"
        }
      )
      |> render_submit()

    assert html =~ "Recruiter link for Northgate Search"
    url = text(view, "#issued-url")
    assert url =~ ~r"^http://localhost(:\d+)?/r/[a-z2-7]{52}$"

    token = url |> String.split("/") |> List.last()
    recruiter = Links.get_recruiter_link_by_token(token)
    assert recruiter.firm_name == "Northgate Search"
    assert recruiter.quota == 12
    assert has_element?(view, "#recruiter-#{recruiter.id}")

    # Shown once: a fresh visit does not show it again.
    {:ok, _view, html} = live(conn, "/admin")
    refute html =~ token
  end

  test "shows validation errors for a recruiter link", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin")

    html =
      view
      |> form("#recruiter-form",
        recruiter: %{firm_name: "", contact_name: "Sam", contact_email: "nope", quota: "500"}
      )
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert html =~ "must be an email address"
    assert html =~ "less than or equal to 100"
    refute has_element?(view, "#issued")
    assert Links.list_recruiter_links() == []

    html =
      view
      |> form("#recruiter-form", recruiter: %{contact_email: "still-nope"})
      |> render_change()

    assert html =~ "must be an email address"
  end

  test "issues an individual link", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin")
    html = view |> form("#individual-form", individual: %{label: "IND-014"}) |> render_submit()
    assert html =~ "Individual link IND-014"

    token = view |> text("#issued-url") |> String.split("/a/") |> List.last()
    assert {:ok, %{kind: :individual, label: "IND-014"}} = Links.begin_session(token)
    assert view |> element("#individual-usage [data-status]") |> render() =~ "unused"
  end

  test "an individual link needs a label", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin")
    html = view |> form("#individual-form", individual: %{label: " "}) |> render_submit()
    assert html =~ "can&#39;t be blank"
    assert Links.list_individual_links() == []
  end

  test "adjusts a quota, and refuses an invalid one", %{conn: conn} do
    {recruiter, _} = recruiter_link_fixture(%{quota: 10})
    {:ok, view, _} = live(conn, "/admin")

    html =
      view
      |> form("#quota-form-#{recruiter.id}", %{quota: "15"})
      |> render_submit(%{recruiter_id: recruiter.id})

    assert html =~ "is now 15"
    assert Links.get_recruiter_link(recruiter.id).quota == 15

    html =
      view
      |> form("#quota-form-#{recruiter.id}", %{quota: "-3"})
      |> render_submit(%{recruiter_id: recruiter.id})

    assert html =~ "A quota must be a whole number from 0 to 100."
    assert Links.get_recruiter_link(recruiter.id).quota == 15

    assert render_submit(view, "set_quota", %{"recruiter_id" => "-1", "quota" => "5"}) =~
             "A quota must be a whole number"
  end

  test "revokes a recruiter link", %{conn: conn} do
    {recruiter, _} = recruiter_link_fixture()
    {_, c_token} = candidate_link_fixture(recruiter)
    {:ok, view, _} = live(conn, "/admin")

    html = view |> element("#recruiter-#{recruiter.id} button", "Revoke") |> render_click()
    assert html =~ "Link revoked."
    assert view |> element("#recruiter-#{recruiter.id}") |> render() =~ "revoked"
    refute has_element?(view, "#recruiter-#{recruiter.id} button", "Revoke")
    refute has_element?(view, "#quota-form-#{recruiter.id}")
    assert Links.begin_session(c_token) == {:error, :revoked}

    assert render_click(view, "revoke_recruiter", %{"id" => "#{recruiter.id}"}) =~
             "already revoked"
  end

  test "revokes an individual link", %{conn: conn} do
    {link, token} = individual_link_fixture("IND-9")
    {:ok, view, _} = live(conn, "/admin")

    view |> element("#individual-#{link.id} button", "Revoke") |> render_click()
    assert view |> element("#individual-#{link.id} [data-status]") |> render() =~ "revoked"
    assert Links.begin_session(token) == {:error, :revoked}

    assert render_click(view, "revoke_link", %{"id" => "-1"}) =~ "not found or is already revoked"
  end

  test "the usage table counts minted, started, completed and abandoned", %{conn: conn} do
    {recruiter, _} = recruiter_link_fixture(%{quota: 10})
    candidate_link_fixture(recruiter)
    {started, _} = candidate_link_fixture(recruiter)
    {:ok, _} = Links.mark_started(started)
    {abandoned, _} = candidate_link_fixture(recruiter)
    {:ok, abandoned} = Links.mark_started(abandoned)
    backdate_start(abandoned, 3 * 60 * 60)
    {done, _} = candidate_link_fixture(recruiter)
    {:ok, done} = Links.mark_started(done)
    {:ok, _} = Links.mark_completed(done)

    {ind, _} = individual_link_fixture("IND-2")
    {:ok, ind} = Links.mark_started(ind, %{role_group: :people})
    backdate_start(ind, 3 * 60 * 60)

    {:ok, view, _} = live(conn, "/admin")
    row = "#recruiter-#{recruiter.id}"
    count = fn name -> text(view, "#{row} [data-count='#{name}']") end

    assert count.("minted") == "4"
    assert count.("started") == "1"
    assert count.("completed") == "1"
    assert count.("abandoned") == "1"
    assert count.("quota-used") == "2"

    assert text(view, "#individual-#{ind.id} [data-status]") == "abandoned"
    assert view |> element("#individual-#{ind.id}") |> render() =~ "People"
  end

  test "is not reachable on the public endpoint", %{conn: conn} do
    conn = Phoenix.ConnTest.dispatch(conn, AiInPracticeWeb.Endpoint, :get, "/admin", nil)
    assert conn.status == 404
  end
end
