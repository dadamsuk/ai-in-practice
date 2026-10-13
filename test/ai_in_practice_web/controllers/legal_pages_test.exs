defmodule AiInPracticeWeb.LegalPagesTest do
  # The privacy notice and terms (PRD §10 "Legal", card #708): they render,
  # they are linked from every public footer, and they say what the PRD
  # requires them to say.
  use AiInPracticeWeb.ConnCase, async: true

  import AiInPractice.LinksFixtures

  alias AiInPractice.Links

  defp section(html, id) do
    html |> LazyHTML.from_document() |> LazyHTML.query("##{id}") |> LazyHTML.text()
  end

  describe "GET /privacy" do
    test "names the controller, what is never kept and the in-memory session", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "<title"
      assert html =~ "Privacy notice"
      assert html =~ "DSC Ltd"
      assert html =~ "controller"
      assert section(html, "updated") =~ ~r/last updated \d{1,2} \w+ 20\d\d/

      never = section(html, "never-kept")
      assert never =~ "Your answers"
      assert never =~ "Both reports"
      assert never =~ "Your name, contact details"

      memory = section(html, "in-memory")
      assert memory =~ "only in the server's memory"
      assert memory =~ "two minutes"
      assert memory =~ "an hour after your reports are ready"
      assert memory =~ "40 minutes"
    end

    test "lists what is kept: link and usage data only, a hash of each link", %{conn: conn} do
      kept = conn |> get(~p"/privacy") |> html_response(200) |> section("kept")

      assert kept =~ "one-way hash"
      assert kept =~ "role group"
      assert kept =~ "firm's name, a contact name and email address"
      assert kept =~ "a label DSC chooses"
    end

    test "names every third party in the data path", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)
      parties = section(html, "third-parties")

      assert parties =~ "cloudflare"
      assert parties =~ "readable form"
      assert parties =~ "openrouter"
      assert parties =~ "zero data retention"
      assert parties =~ "model provider"
      assert html =~ "no analytics or tracking"
      assert html =~ "github.com/dadamsuk/ai-in-practice"
      assert html =~ "Information Commissioner"
      assert html =~ "legitimate interest"
    end

    test "is public, needs no token and links to the terms", %{conn: conn} do
      conn = get(conn, ~p"/privacy")

      assert conn.status == 200
      assert html_response(conn, 200) =~ ~s(href="/terms")
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end

  describe "GET /terms" do
    test "states the conversation-starter, not-a-decision position", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)

      assert html =~ "<title"
      assert section(html, "updated") =~ "last updated"
      assert section(html, "conversation-starter") =~ "no score, no rank and no pass mark"

      decision = section(html, "not-a-decision")
      assert decision =~ "makes no decision about you"
      assert decision =~ "UK GDPR (Article 22)"
      assert decision =~ "one input to their own human judgement"
    end

    test "covers identity, bias and fair use, and links to the privacy notice", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)

      assert html =~ "does not check who took part"
      assert section(html, "fairness") =~ "Equality Act 2010"
      assert section(html, "fair-use") =~ "Links are personal and work once"
      assert html =~ ~s(href="/privacy")
      assert html =~ "England and Wales"
    end
  end

  describe "links to the privacy notice and terms" do
    test "are in the footer of the home page, opening in a new tab", %{conn: conn} do
      footer = conn |> get(~p"/") |> html_response(200) |> section("running-foot")
      assert footer =~ "privacy"
      assert footer =~ "terms"

      html = build_conn() |> get(~p"/") |> html_response(200)
      assert html =~ ~s(<a href="/privacy" target="_blank" rel="noopener">privacy</a>)
      assert html =~ ~s(<a href="/terms" target="_blank" rel="noopener">terms</a>)
    end

    test "are in the footer of the recruiter page and the start screen", %{conn: conn} do
      {recruiter, r_token} = recruiter_link_fixture()
      {:ok, _, c_token} = Links.mint_candidate_link(recruiter, :finance)

      for path <- [~p"/r/#{r_token}", ~p"/a/#{c_token}"] do
        html = conn |> recycle() |> get(path) |> html_response(200)
        assert html =~ ~s(href="/privacy"), "no privacy link on #{path}"
        assert html =~ ~s(href="/terms"), "no terms link on #{path}"
      end
    end

    test "are in the footer of the dead-end page for an unusable link", %{conn: conn} do
      html = conn |> get(~p"/a/#{Links.Token.generate()}") |> html_response(404)
      assert html =~ ~s(href="/privacy")
    end

    test "are left out of the admin pages, which are not on the public site" do
      html =
        build_conn()
        |> Phoenix.ConnTest.dispatch(AiInPracticeWeb.AdminEndpoint, :get, "/admin")
        |> html_response(200)

      assert html =~ ~s(id="running-foot")
      refute html =~ ~s(href="/privacy")
      refute html =~ ~s(href="/terms")
    end
  end
end
