defmodule AiInPractice.Reports.PDFTest do
  use AiInPractice.DataCase, async: true

  import AiInPractice.ReportFixtures

  alias AiInPractice.Reports.{Content, PDF}

  # The text drawn on each page: every `(...) Tj` in each content stream.
  defp pages(pdf) do
    ~r/stream\n(.*?)\nendstream/s
    |> Regex.scan(pdf)
    |> Enum.map(fn [_, stream] ->
      ~r/\(((?:\\.|[^\\)])*)\) Tj/
      |> Regex.scan(stream)
      |> Enum.map_join("\n", fn [_, text] -> String.replace(text, ~r/\\(.)/, "\\1") end)
    end)
  end

  defp text(pdf), do: pdf |> pages() |> Enum.join("\n")

  test "is a well-formed A4 PDF with a valid cross-reference table" do
    pdf = PDF.render(:candidate, report_fixture(), meta_fixture())

    assert pdf =~ ~r/\A%PDF-1\.4\n/
    assert String.ends_with?(pdf, "%%EOF\n")
    assert pdf =~ "/MediaBox [0 0 595 842]"

    [_, startxref] = Regex.run(~r/startxref\n(\d+)\n%%EOF\n\z/, pdf)
    xref_at = String.to_integer(startxref)
    assert binary_part(pdf, xref_at, 4) == "xref"

    # Each xref offset points at its object.
    offsets = for [_, o] <- Regex.scan(~r/^(\d{10}) 00000 n $/m, pdf), do: String.to_integer(o)

    for {offset, n} <- Enum.with_index(offsets, 1) do
      assert binary_part(pdf, offset, byte_size("#{n} 0 obj")) == "#{n} 0 obj"
    end
  end

  test "the candidate PDF carries the header, every section and the versions" do
    text = text(PDF.render(:candidate, report_fixture(), meta_fixture()))

    for expected <- [
          "DSC",
          "AI in Practice",
          "Your report",
          "role group: Finance",
          "date: 13 October 2026",
          "answers: typed",
          "link: from a recruiter",
          "What you are doing well",
          "The main gap",
          "In the next two weeks",
          "rubric v",
          "code "
        ] do
      assert text =~ expected
    end

    refute text =~ Content.statement() |> String.slice(0, 40)
  end

  test "the assessor statement is on every page of a multi-page assessor report" do
    long = String.duplicate("A long answer about drafting papers with AI tools. ", 30)
    report = report_fixture([long, long, long, long, long])
    pages = pages(PDF.render(:assessor, report, meta_fixture()))

    assert length(pages) > 1

    for {page, n} <- Enum.with_index(pages, 1) do
      assert page =~ "This report is a conversation starter."
      assert page =~ "page #{n} of #{length(pages)}"
      assert page =~ "Finance"
    end
  end

  test "no internal levels or confidence labels appear in either PDF" do
    report = report_fixture()

    for audience <- [:candidate, :assessor] do
      text = text(PDF.render(audience, report, meta_fixture()))
      refute text =~ ~r/\b(developing|capable|advanced|insufficient)\b/i
      refute text =~ ~r/\bmedium\b/i
    end
  end

  test "escapes PDF string syntax and maps typographic characters to WinAnsi" do
    report =
      report_fixture(["One."], %{
        "summary" => "Costs (roughly) fell \\ rose – “quickly” — it’s fine…"
      })

    pdf = PDF.render(:candidate, report, meta_fixture())
    assert pdf =~ "Costs \\(roughly\\) fell \\\\ rose \x96 \x93quickly\x94 \x97 it\x92s fine\x85"
  end

  test "a word wider than the page is broken across lines, not run off the edge" do
    url = "https://example.com/" <> String.duplicate("a", 300)

    {:ok, item} =
      AiInPractice.Reading.create_item(%{title: "Long", url: url, areas: [:attitude]})

    report = report_fixture(["One."], %{"reading_picks" => [item.id]})
    text = text(PDF.render(:candidate, report, meta_fixture()))

    lines =
      text |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "https://example.com/"))

    assert [first] = lines
    # Courier at 8.5pt: 483pt of line holds 94 characters.
    assert String.length(first) <= 95
    assert text |> String.replace("\n", "") |> String.contains?(url)
  end

  test "file names" do
    assert PDF.filename(:candidate) == "ai-in-practice-your-report.pdf"
    assert PDF.filename(:assessor) == "ai-in-practice-assessor-report.pdf"
  end
end
