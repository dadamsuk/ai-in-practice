defmodule AiInPracticeWeb.DesignSystemTest do
  # PRD §13.2: self-hosted fonts, no third-party requests, and the visual
  # rules of the system, checked against the stylesheet and rendered pages.
  use AiInPracticeWeb.ConnCase

  import Phoenix.LiveViewTest

  alias AiInPractice.Links

  @css_path "assets/css/app.css"
  @css File.read!(@css_path)
  @external_resource @css_path

  defp asset_urls(html) do
    ~r/(?:src|href|action|content)="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, url] -> url end)
    |> Enum.filter(&(&1 =~ ~r{^(https?:)?//|^/}))
  end

  @tag :third_party_assets
  test "public, recruiter, assessment and admin pages reference only same-origin assets", %{
    conn: conn
  } do
    {:ok, recruiter, r_token} =
      Links.create_recruiter_link(%{
        firm_name: "F",
        contact_name: "C",
        contact_email: "c@f.example"
      })

    {:ok, _, c_token} = Links.mint_candidate_link(recruiter, :finance)
    admin_get = &Phoenix.ConnTest.dispatch(build_conn(), AiInPracticeWeb.AdminEndpoint, :get, &1)

    pages = [
      conn |> get(~p"/") |> html_response(200),
      build_conn() |> get(~p"/privacy") |> html_response(200),
      build_conn() |> get(~p"/terms") |> html_response(200),
      build_conn() |> get(~p"/check") |> html_response(200),
      build_conn() |> get(~p"/r/#{r_token}") |> html_response(200),
      build_conn() |> get(~p"/a/#{c_token}") |> html_response(200),
      build_conn() |> get(~p"/a/#{Links.Token.generate()}") |> html_response(404),
      build_conn() |> get(~p"/reports/AAAAAAAAAAAAAAAAAAAAAAAA/candidate") |> html_response(404),
      admin_get.("/admin") |> html_response(200),
      admin_get.("/admin/reading") |> html_response(200)
    ]

    for html <- pages do
      urls = asset_urls(html)
      assert urls != []

      for url <- urls do
        refute url =~ ~r{^(https?:)?//}, "third-party URL in page: #{url}"
      end

      refute html =~ "fonts.googleapis"
      refute html =~ "fonts.gstatic"
    end
  end

  @tag :third_party_assets
  test "the stylesheet loads fonts only from /fonts, and every font file exists" do
    urls = Regex.scan(~r/url\(\s*"?([^")]+)"?\s*\)/, @css) |> Enum.map(fn [_, u] -> u end)
    assert urls != []

    for url <- urls do
      assert String.starts_with?(url, "/fonts/"), "non-local url() in CSS: #{url}"
      assert File.exists?(Path.join("priv/static", url)), "missing font file #{url}"
    end

    refute @css =~ "@import"
  end

  test "font files are served with their OFL licences alongside", %{conn: conn} do
    conn = get(conn, "/fonts/source-serif-4-latin-400-normal.woff2")
    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "font/woff2"

    assert File.exists?("priv/static/fonts/OFL-source-serif-4.txt")
    assert File.exists?("priv/static/fonts/OFL-ibm-plex-mono.txt")
  end

  test "the colour tokens match the PRD" do
    for {token, value} <- [
          ground: "#f8f4ea",
          ink: "#111111",
          "ink-quiet": "#555555",
          hair: "#8c8c8c",
          band: "#e4dfd2",
          accent: "#8a2a1e"
        ] do
      assert @css =~ "--#{token}: #{value};"
    end

    # Cream on screen, white on paper.
    assert @css =~ ~r/@media print\s*\{\s*:root\s*\{\s*--ground: #ffffff;\s*--hair: #c4c4c4;/
  end

  test "no rounded corners, shadows, gradients or transitions" do
    for {property, allowed} <- [
          {"border-radius", "0"},
          {"box-shadow", "none"},
          {"transition", "none"},
          {"animation", "none"}
        ] do
      for [_, value] <- Regex.scan(~r/#{property}:\s*([^;]+);/, @css) do
        assert String.trim(value) == allowed, "#{property}: #{value}"
      end
    end

    refute @css =~ "gradient("

    # The browser's own file picker button is rounded unless told otherwise.
    assert @css =~ ~r/::file-selector-button \{[^}]*border-radius: 0;/
  end

  test "nothing centred and no capitals" do
    refute @css =~ ~r/text-align:\s*center/
    refute @css =~ ~r/margin(-inline)?:[^;]*\bauto\b/
    refute @css =~ ~r/justify-content:\s*center/
    refute @css =~ ~r/text-transform:\s*(uppercase|capitalize)/
  end

  test "the accent is used only by the primary button and the recording indicator" do
    uses = Regex.scan(~r/var\(--accent\)/, @css)
    assert length(uses) == 4
    assert @css =~ ~r/\.button-primary \{[^}]*var\(--accent\)[^}]*var\(--accent\)/
    # Never on small type: the indicator is full size and bold.
    assert @css =~
             ~r/\.recording \{[^}]*font-size: 18px;[^}]*font-weight: 600;[^}]*var\(--accent\)/

    # The recording light: a solid square of the accent, a unit across, on
    # the same element as the words, so it adds no use to the screen.
    assert @css =~
             ~r/\.recording::before \{[^}]*width: var\(--unit\);[^}]*height: var\(--unit\);[^}]*background: var\(--accent\);/
  end

  test "controls look like controls without focus: a full border, and a drop-down arrow" do
    assert @css =~
             ~r/select,\ntextarea \{[^}]*border: 2px solid var\(--ink\);[^}]*border-radius: 0;/

    refute @css =~ ~r/select,\ntextarea \{[^}]*border: 0;/
    # The arrow is a triangle drawn with borders: no icon, no image.
    assert @css =~ ~r/\.select::after \{[^}]*border-top: 8px solid var\(--ink\);/
    assert @css =~ ~r/\.select select \{[^}]*padding-right:/
  end

  test "buttons are dark brown with light text; a disabled one is drawn quiet" do
    assert @css =~ "--button: #3d2b1f;"

    assert @css =~
             ~r/\.button \{[^}]*color: var\(--ground\);[^}]*background: var\(--button\);[^}]*border: 2px solid var\(--button\);/

    assert @css =~
             ~r/::file-selector-button \{[^}]*color: var\(--ground\);[^}]*background: var\(--button\);/

    assert @css =~
             ~r/\.button:disabled \{[^}]*color: var\(--ink-quiet\);[^}]*background: var\(--ground\);/
  end

  test "a report on screen reads as parts: ruled sections, areas, labels beside their text (#804)" do
    assert @css =~ ~r/\.report-section \{[^}]*border-top: var\(--hairline\);/
    assert @css =~ ~r/\.report-section \{[^}]*font-size: 24px;/
    assert @css =~ ~r/\.report-area \{[^}]*font-size: 20px;/
    assert @css =~ ~r/\.labelled \{[^}]*display: grid;[^}]*grid-template-columns: 12rem 1fr;/
    # Stacked on a narrow screen, so nothing scrolls sideways.
    assert @css =~
             ~r/@media \(max-width: 40rem\) \{\s*\.labelled \{\s*grid-template-columns: 1fr;/

    assert @css =~ ~r/\.report \.statement \{[^}]*border-left: var\(--rule\);/
    # Rules, not boxes: nothing in the report draws a full border.
    refute @css =~ ~r/\.report[^{]*\{[^}]*\bborder: /
  end

  test "a sent question goes from the screen but keeps its space" do
    assert @css =~ ~r/\.question-answered \{\s*visibility: hidden;\s*\}/
    refute @css =~ ~r/\.question-answered \{[^}]*display: none/
  end

  test "rules: 3px ink for structure, 2px hairline for separators" do
    assert @css =~ "--rule: 3px solid var(--ink);"
    assert @css =~ "--hairline: 2px solid var(--hair);"
  end

  test "line heights sit on the 12px unit" do
    assert @css =~ "--unit: 12px;"

    for [_, value] <- Regex.scan(~r/line-height:\s*([^;]+);/, @css) do
      assert value =~ "var(--unit)", "line-height off the grid: #{value}"
    end
  end

  # The accent is the primary button's alone; a screen may show it at most
  # twice. Walks every screen of the candidate journey on the fake model.
  test "each screen of the candidate journey uses the accent at most twice", %{conn: conn} do
    {:ok, recruiter, _} =
      Links.create_recruiter_link(%{
        firm_name: "F",
        contact_name: "C",
        contact_email: "c@f.example"
      })

    {:ok, _, token} = Links.mint_candidate_link(recruiter, :finance)
    accents = &length(Regex.scan(~r/button-primary/, &1))

    {:ok, view, html} = live(conn, ~p"/a/#{token}")
    screens = [html]

    view |> form("#begin-form") |> render_submit()
    screens = [wait_for(view, "#question") | screens]

    for n <- 1..5 do
      view |> form("#answer-form", %{answer: "Answer #{n}."}) |> render_submit()
      if n < 5, do: wait_for(view, "#question[data-number='#{n + 1}']")
    end

    screens = [wait_for(view, "#candidate-report") | screens]

    for html <- screens do
      count = accents.(html)
      assert count in 1..2, "accent used #{count} times"
    end
  end

  test "the check page's form uses the accent once, and its answers do not use it", %{
    conn: conn
  } do
    accents = &length(Regex.scan(~r/button-primary/, &1))
    assert conn |> get(~p"/check") |> html_response(200) |> accents.() == 1

    boundary = "designboundary"

    body =
      "--#{boundary}\r\ncontent-disposition: form-data; name=\"report\"; filename=\"r.pdf\"\r\n\r\n%PDF-1.7\r\n--#{boundary}--\r\n"

    html =
      build_conn()
      |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
      |> post(~p"/check", body)
      |> html_response(200)

    assert accents.(html) == 0
  end

  defp wait_for(view, selector) do
    Enum.find_value(1..300, fn _ ->
      if has_element?(view, selector), do: render(view), else: Process.sleep(10) && nil
    end) || flunk("#{selector} never appeared")
  end
end
