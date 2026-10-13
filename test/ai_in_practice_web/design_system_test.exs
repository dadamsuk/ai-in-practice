defmodule AiInPracticeWeb.DesignSystemTest do
  # PRD §13.2: self-hosted fonts, no third-party requests, and the visual
  # rules of the system, checked against the stylesheet and rendered pages.
  use AiInPracticeWeb.ConnCase

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
  test "public and admin pages reference only same-origin assets", %{conn: conn} do
    pages = [
      conn |> get(~p"/") |> html_response(200),
      Phoenix.ConnTest.dispatch(build_conn(), AiInPracticeWeb.AdminEndpoint, :get, "/admin")
      |> html_response(200)
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
          ground: "#ffffff",
          ink: "#111111",
          "ink-quiet": "#555555",
          hair: "#8c8c8c",
          band: "#e2e2e2",
          accent: "#8a2a1e"
        ] do
      assert @css =~ "--#{token}: #{value};"
    end

    assert @css =~ ~r/@media print\s*\{\s*:root\s*\{\s*--hair: #c4c4c4;/
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
  end

  test "nothing centred and no capitals" do
    refute @css =~ ~r/text-align:\s*center/
    refute @css =~ ~r/margin(-inline)?:[^;]*\bauto\b/
    refute @css =~ ~r/justify-content:\s*center/
    refute @css =~ ~r/text-transform:\s*(uppercase|capitalize)/
  end

  test "the accent is used only by the primary button" do
    uses = Regex.scan(~r/var\(--accent\)/, @css)
    assert length(uses) == 2
    assert @css =~ ~r/\.button-primary \{[^}]*var\(--accent\)[^}]*var\(--accent\)/
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
end
