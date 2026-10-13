defmodule AiInPractice.Reports.PDFTest do
  use AiInPractice.DataCase, async: true

  import AiInPractice.ReportFixtures

  alias AiInPractice.Reports.{Content, Payload, PDF, Signing}

  @moduletag :tmp_dir

  # The text of each page, from poppler's pdftotext (CI installs it).
  defp pages(pdf, dir) do
    path = Path.join(dir, "report-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, pdf)
    {text, 0} = System.cmd("pdftotext", ["-enc", "UTF-8", path, "-"])
    text |> String.split("\f") |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp text(pdf, dir), do: pdf |> pages(dir) |> Enum.join("\n")

  # pdftotext breaks lines where the PDF does.
  defp flat(text), do: text |> String.replace(~r/\s+/u, " ")

  defp keyring do
    {:ok, keyring} = Signing.parse(private_key: Signing.generate().private_key)
    keyring
  end

  defp long_report do
    long = String.duplicate("A long answer about drafting papers with AI tools. ", 40)
    report_fixture([long, long, long, long, long])
  end

  test "is an A4 PDF with Source Serif 4 and IBM Plex Mono embedded" do
    pdf = PDF.render(:candidate, report_fixture(), meta_fixture())

    assert pdf =~ ~r/\A%PDF-1\.\d/
    assert pdf =~ "%%EOF"

    # A4: 210 by 297 mm.
    [[w, h] | _] =
      for [_, w, h] <- Regex.scan(~r{/MediaBox\s*\[\s*0 0 ([\d.]+) ([\d.]+)\s*\]}, pdf),
          do: [String.to_float(w), String.to_float(h)]

    assert_in_delta w, 595.28, 0.1
    assert_in_delta h, 841.89, 0.1

    # By family: a machine with its own copy of a face installed may name
    # its weights differently.
    fonts = for [_, name] <- Regex.scan(~r"/BaseFont\s*/[A-Z]{6}\+([^/\s>]+)", pdf), do: name

    for family <- ~w(SourceSerif4 IBMPlexMono) do
      assert Enum.any?(fonts, &String.starts_with?(&1, family)),
             "#{family} is not embedded: #{inspect(fonts)}"
    end

    assert pdf =~ "/FontFile2"
    refute pdf =~ ~r{/BaseFont\s*/(Helvetica|Courier|Times)}
  end

  test "the candidate PDF carries the header, every section and the versions", %{tmp_dir: dir} do
    text = flat(text(PDF.render(:candidate, report_fixture(), meta_fixture()), dir))

    for expected <- [
          "DSC",
          "AI in Practice",
          "Your report",
          "role group date answers link",
          "Finance 13 October 2026 typed from a recruiter",
          "Summary",
          "The five areas",
          "Understanding",
          "Attitude",
          "how sure this is",
          "What you are doing well",
          "The main gap",
          "Next steps",
          "In the next two weeks",
          "how you will know it helped",
          "What the assessor report contains",
          "Finance · 2026-10-13 · code ",
          "· rubric v",
          "· model ",
          "page 1 of"
        ] do
      assert text =~ expected
    end

    refute text =~ String.slice(Content.statement(), 0, 40)
  end

  test "the assessor PDF carries the statement and every section", %{tmp_dir: dir} do
    text = flat(text(PDF.render(:assessor, report_fixture(), meta_fixture()), dir))

    for expected <- [
          "Assessor report",
          Content.statement(),
          "a strong answer for this role would include",
          "where this one fell short",
          "What to explore next",
          "Questions to ask in person",
          "listen for",
          "I used AI to draft the quarterly pricing"
        ] do
      assert text =~ expected
    end

    refute text =~ "What you are doing well"
    refute text =~ "In the next two weeks"
  end

  test "the statement, the foot and the page count are on every page of a long assessor report",
       %{tmp_dir: dir} do
    pages = pages(PDF.render(:assessor, long_report(), meta_fixture()), dir)
    count = length(pages)
    assert count > 1

    for {page, n} <- Enum.with_index(pages, 1) do
      page = flat(page)
      assert page =~ Content.statement()
      assert page =~ "page #{n} of #{count}"
      assert page =~ "Finance · 2026-10-13"
      assert page =~ "DSC AI in Practice"
    end
  end

  test "the head and foot are on every page of a long candidate report", %{tmp_dir: dir} do
    pages = pages(PDF.render(:candidate, long_report(), meta_fixture(%{mode: :voice})), dir)
    count = length(pages)

    for {page, n} <- Enum.with_index(pages, 1) do
      assert flat(page) =~ "page #{n} of #{count}"
      assert flat(page) =~ "DSC AI in Practice"
    end

    assert flat(hd(pages)) =~ "13 October 2026 spoken"
  end

  test "no level labels, confidence labels or scores appear in either PDF", %{tmp_dir: dir} do
    report = report_fixture()

    for audience <- [:candidate, :assessor] do
      text = text(PDF.render(audience, report, meta_fixture()), dir)
      refute text =~ ~r/\b(early|developing|capable|advanced|insufficient)\b/i
      refute text =~ ~r/\b(high|medium|low)\b/i
      refute text =~ ~r{\b\d+\s*/\s*(5|10|100)\b}
      refute text =~ ~r/\bscore/i
    end
  end

  test "report text is printed as written, never read as Typst markup", %{tmp_dir: dir} do
    tricky =
      ~S|#set page(fill: red) = Heading *bold* _it_ $x^2$ <label> @ref `code` \ #import "x"|

    report = report_fixture(["One."], %{"summary" => tricky})

    text = flat(text(PDF.render(:candidate, report, meta_fixture()), dir))

    assert text =~
             ~S|#set page(fill: red) = Heading *bold* _it_ $x^2$ <label> @ref `code` \ #import "x"|
  end

  test "typographic and non-Latin characters survive", %{tmp_dir: dir} do
    report = report_fixture(["One."], %{"summary" => "Costs – “quickly” — it’s fine… Zoë, Łódź."})

    assert text(PDF.render(:candidate, report, meta_fixture()), dir) =~
             "Costs – “quickly” — it’s fine… Zoë, Łódź."
  end

  test "reading items, including a URL longer than the line", %{tmp_dir: dir} do
    url = "https://example.com/" <> String.duplicate("a", 300)

    {:ok, item} =
      AiInPractice.Reading.create_item(%{
        title: "A long one",
        url: url,
        note: "For finance leads.",
        areas: [:attitude]
      })

    report = report_fixture(["One."], %{"reading_picks" => [item.id]})
    pdf = PDF.render(:candidate, report, meta_fixture())
    text = text(pdf, dir)

    assert text =~ "Further reading"
    assert text =~ "A long one"
    assert text =~ "For finance leads."
    assert text |> String.replace(~r/[\s\x{200B}]+/u, "") |> String.contains?(url)
    assert pdf =~ "/URI(#{url})"

    # Broken across lines rather than run off the page.
    lines = text |> String.replace("\u200B", "") |> String.split("\n")
    assert Enum.all?(lines, &(String.length(&1) <= 100))
  end

  describe "the signed payload" do
    test "the assessor PDF embeds an envelope that verifies and matches the report" do
      keyring = keyring()
      report = report_fixture()
      pdf = PDF.render(:assessor, report, meta_fixture(), keyring)

      assert {:ok, envelope} = PDF.attachment(pdf, Signing.attachment_name())
      assert {:ok, payload} = Signing.verify(envelope, keyring)
      assert payload == Payload.assessor(report, meta_fixture())
    end

    test "a long report's compressed envelope is read back too" do
      keyring = keyring()
      pdf = PDF.render(:assessor, long_report(), meta_fixture(), keyring)

      assert pdf =~ ~r{/Type/EmbeddedFile[^>]*/FlateDecode}
      assert {:ok, envelope} = PDF.attachment(pdf, Signing.attachment_name())
      assert {:ok, _payload} = Signing.verify(envelope, keyring)
    end

    test "is signed with the configured key by default" do
      pdf = PDF.render(:assessor, report_fixture(), meta_fixture())
      {:ok, envelope} = PDF.attachment(pdf, Signing.attachment_name())
      assert {:ok, _} = Signing.verify(envelope)
    end

    test "the candidate PDF is not signed" do
      pdf = PDF.render(:candidate, report_fixture(), meta_fixture())
      assert PDF.attachment(pdf, Signing.attachment_name()) == :error
      refute pdf =~ "EmbeddedFile"
    end

    test "editing the embedded payload breaks the signature" do
      keyring = keyring()
      pdf = PDF.render(:assessor, report_fixture(), meta_fixture(), keyring)
      {:ok, envelope} = PDF.attachment(pdf, Signing.attachment_name())

      edited = String.replace(envelope, "Finance", "Finanze")
      assert edited != envelope
      assert Signing.verify(edited, keyring) == {:error, :bad_signature}
    end
  end

  describe "attachment/2" do
    defp handmade(dict_extra, data) do
      "%PDF-1.7\n1 0 obj\n<</Type/Filespec/F(x.json)/UF(x.json)/EF<</F 2 0 R/UF 2 0 R>>>>\nendobj\n" <>
        "2 0 obj\n<</Length #{byte_size(data)}/Type/EmbeddedFile#{dict_extra}>>\nstream\n" <>
        data <> "\nendstream\nendobj\n%%EOF\n"
    end

    test "reads plain and Flate-compressed streams" do
      assert PDF.attachment(handmade("", ~s({"a":1})), "x.json") == {:ok, ~s({"a":1})}

      compressed = :zlib.compress(~s({"b":2}))

      assert PDF.attachment(handmade("/Filter/FlateDecode", compressed), "x.json") ==
               {:ok, ~s({"b":2})}
    end

    test "is :error for a missing name, corrupt data, a short stream or not a PDF" do
      assert PDF.attachment(handmade("", "{}"), "other.json") == :error
      assert PDF.attachment(handmade("/Filter/FlateDecode", "not zlib"), "x.json") == :error

      truncated = handmade("", "{}") |> String.replace("/Length 2", "/Length 9999")
      assert PDF.attachment(truncated, "x.json") == :error

      assert PDF.attachment("plain text", "x.json") == :error
      assert PDF.attachment("", "x.json") == :error
    end
  end

  test "a URL short enough for the line is printed as it is", %{tmp_dir: dir} do
    {:ok, item} =
      AiInPractice.Reading.create_item(%{
        title: "Short",
        url: "https://example.com/short",
        areas: [:attitude]
      })

    report = report_fixture(["One."], %{"reading_picks" => [item.id]})

    assert text(PDF.render(:candidate, report, meta_fixture()), dir) =~
             "\nhttps://example.com/short\n"
  end

  test "file names" do
    assert PDF.filename(:candidate) == "ai-in-practice-your-report.pdf"
    assert PDF.filename(:assessor) == "ai-in-practice-assessor-report.pdf"
  end
end
