defmodule AiInPractice.Reports.PDF do
  @moduledoc """
  An interim A4 PDF of either report, written directly (PDF 1.4, the
  standard Helvetica and Courier faces, uncompressed text), so the journey
  can be walked end to end with both downloads.

  Epic 5 replaces this with the designed templates (#706) and signs the
  assessor report (#707). Until then the assessor PDF carries no
  signature, and nothing says it does.

  The content is `AiInPractice.Reports.Content`, the same blocks the
  reports screen shows. Every page has a running head, a running foot with
  the role group, date and versions and, on the assessor report, the
  standing statement (PRD §9).
  """

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Reports.Content
  alias AiInPractice.{RoleGroups, Version}

  @page_w 595
  @page_h 842
  @margin 56
  @head_y @page_h - 40
  @body_top @page_h - 80
  @width @page_w - 2 * @margin

  # Helvetica advance widths (per 1000 em) for printable ASCII, from the AFM.
  @helvetica_widths [
                      278,
                      278,
                      355,
                      556,
                      556,
                      889,
                      667,
                      191,
                      333,
                      333,
                      389,
                      584,
                      278,
                      333,
                      278,
                      278,
                      556,
                      556,
                      556,
                      556,
                      556,
                      556,
                      556,
                      556,
                      556,
                      556,
                      278,
                      278,
                      584,
                      584,
                      584,
                      556,
                      1015,
                      667,
                      667,
                      722,
                      722,
                      667,
                      611,
                      778,
                      722,
                      278,
                      500,
                      667,
                      556,
                      833,
                      722,
                      778,
                      667,
                      778,
                      722,
                      667,
                      611,
                      722,
                      667,
                      944,
                      667,
                      667,
                      611,
                      278,
                      278,
                      278,
                      469,
                      556,
                      333,
                      556,
                      556,
                      500,
                      556,
                      556,
                      278,
                      556,
                      556,
                      222,
                      222,
                      500,
                      222,
                      833,
                      556,
                      556,
                      556,
                      556,
                      333,
                      500,
                      278,
                      556,
                      500,
                      722,
                      500,
                      500,
                      500,
                      334,
                      260,
                      334,
                      584
                    ]
                    |> Enum.with_index(32)
                    |> Map.new(fn {w, c} -> {c, w} end)

  @doc """
  The PDF of the `:candidate` or `:assessor` report, as a binary.
  `meta` is as `AiInPractice.Reports.Content.meta/0`.
  """
  @spec render(:candidate | :assessor, Report.t(), Content.meta()) :: binary()
  def render(audience, %Report{} = report, meta) when audience in [:candidate, :assessor] do
    blocks =
      case audience do
        :candidate -> Content.candidate(report)
        :assessor -> Content.assessor(report)
      end

    title = Content.title(audience)

    header_lines =
      [{:title, title}] ++
        for({label, value} <- Content.header(meta), do: {:mono, "#{label}: #{value}"}) ++
        [{:gap, 12}]

    lines = header_lines ++ Enum.flat_map(blocks, &layout/1)
    pages = paginate(lines)
    foot = foot(audience, meta)
    count = length(pages)

    streams =
      pages
      |> Enum.with_index(1)
      |> Enum.map(fn {page_lines, n} -> page_stream(page_lines, foot, n, count) end)

    document(streams, "AI in Practice: #{String.downcase(title)}")
  end

  @doc "The file name a report downloads as."
  @spec filename(:candidate | :assessor) :: String.t()
  def filename(:candidate), do: "ai-in-practice-your-report.pdf"
  def filename(:assessor), do: "ai-in-practice-assessor-report.pdf"

  ## Layout: blocks into lines of {font, size, indent, text}

  defp layout({:h2, text}), do: [{:gap, 10} | wrap(text, :bold, 14, 0)] ++ [{:gap, 2}]
  defp layout({:h3, text}), do: [{:gap, 6} | wrap(text, :bold, 11.5, 0)]
  defp layout({:p, text}), do: wrap(text, :regular, 10.5, 0) ++ [{:gap, 5}]
  defp layout({:strong, text}), do: wrap(text, :bold, 10.5, 0) ++ [{:gap, 3}]
  defp layout({:quote, text}), do: wrap("“#{text}”", :regular, 10.5, 16) ++ [{:gap, 5}]
  defp layout({:statement, text}), do: wrap(text, :bold, 10.5, 0) ++ [{:gap, 8}]

  defp layout({:labelled, label, text}),
    do: wrap(label, :mono, 8.5, 0) ++ wrap(text, :regular, 10.5, 0) ++ [{:gap, 5}]

  defp layout({:list, items}),
    do: Enum.flat_map(items, &(wrap("- " <> &1, :regular, 10.5, 8) ++ [{:gap, 3}]))

  defp layout({:reading, item}) do
    wrap(item.title, :bold, 10.5, 0) ++
      if(item.url, do: wrap(item.url, :mono, 8.5, 0), else: []) ++
      if(item.note, do: wrap(item.note, :regular, 10.5, 0), else: []) ++ [{:gap, 5}]
  end

  defp wrap(text, font, size, indent) do
    max = @width - indent

    text
    |> to_string()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.flat_map(&split_long(&1, font, size, max))
    |> Enum.reduce([], &add_word(&1, &2, font, size, max))
    |> Enum.reverse()
    |> Enum.map(&{:text, font, size, indent, &1})
  end

  defp add_word(word, [], _font, _size, _max), do: [word]

  defp add_word(word, [current | rest] = lines, font, size, max) do
    candidate = current <> " " <> word
    if width(candidate, font, size) <= max, do: [candidate | rest], else: [word | lines]
  end

  defp fill(grapheme, acc, fits?) do
    if fits?.(acc <> grapheme), do: {:cont, acc <> grapheme}, else: {:cont, acc, grapheme}
  end

  # A word wider than the line (a long address, say) is broken across lines.
  defp split_long(word, font, size, max) do
    if width(word, font, size) <= max do
      [word]
    else
      fits? = &(width(&1, font, size) <= max)

      word
      |> String.graphemes()
      |> Enum.chunk_while("", &fill(&1, &2, fits?), &{:cont, &1, ""})
    end
  end

  defp width(text, :mono, size), do: String.length(text) * 600 * size / 1000

  defp width(text, font, size) do
    factor = if font == :bold, do: 1.08, else: 1.0

    units =
      text |> String.to_charlist() |> Enum.reduce(0, &(&2 + Map.get(@helvetica_widths, &1, 556)))

    units * factor * size / 1000
  end

  defp height({:gap, h}), do: h
  defp height({:title, _}), do: 28
  defp height({:mono, _}), do: 12
  defp height({:text, _font, size, _indent, _}), do: size * 1.4

  # Leaves room at the foot for the running foot (and the statement).
  defp paginate(lines) do
    bottom = 110

    {pages, current, _y} =
      Enum.reduce(lines, {[], [], @body_top}, fn line, {pages, current, y} ->
        h = height(line)

        if y - h < bottom and current != [],
          do: start_page(line, h, [Enum.reverse(current) | pages]),
          else: {pages, [line | current], y - h}
      end)

    pages = if current == [], do: pages, else: [Enum.reverse(current) | pages]
    pages |> Enum.reverse() |> Enum.map(&drop_leading_gaps/1)
  end

  defp start_page({:gap, _}, _h, pages), do: {pages, [], @body_top}
  defp start_page(line, h, pages), do: {pages, [line], @body_top - h}

  defp drop_leading_gaps([{:gap, _} | rest]), do: drop_leading_gaps(rest)
  defp drop_leading_gaps(lines), do: lines

  defp foot(audience, meta) do
    versions =
      "#{RoleGroups.name(meta.role_group)}  #{Date.to_iso8601(meta.date)}  " <>
        "code #{Version.code_version()}  rubric v#{Version.rubric_version()}  model #{Version.model()}"

    statement = if audience == :assessor, do: wrap(Content.statement(), :regular, 8, 0), else: []
    %{versions: versions, statement: statement}
  end

  ## Drawing

  defp page_stream(lines, foot, n, count) do
    head = [
      text_op(:bold, 10, @margin, @head_y, "DSC"),
      text_op(:regular, 10, @margin + 34, @head_y, "AI in Practice"),
      rule(@head_y - 10, 3)
    ]

    {body, _y} =
      Enum.reduce(lines, {[], @body_top}, fn line, {ops, y} ->
        y = y - height(line)
        {[draw(line, y) | ops], y}
      end)

    statement =
      foot.statement
      |> Enum.with_index()
      |> Enum.map(fn {{:text, font, size, _i, text}, i} ->
        text_op(font, size, @margin, 78 - i * 11, text)
      end)

    foot_ops = [
      rule(92, 1),
      statement,
      text_op(:mono, 7.5, @margin, 40, foot.versions),
      text_op(:mono, 7.5, @page_w - @margin - 60, 28, "page #{n} of #{count}")
    ]

    IO.iodata_to_binary([head, Enum.reverse(body), foot_ops])
  end

  defp draw({:gap, _}, _y), do: []
  defp draw({:title, text}, y), do: text_op(:bold, 20, @margin, y + 6, text)
  defp draw({:mono, text}, y), do: text_op(:mono, 8.5, @margin, y + 2, text)

  defp draw({:text, font, size, indent, text}, y),
    do: text_op(font, size, @margin + indent, y, text)

  defp text_op(font, size, x, y, text) do
    face = %{regular: "/F1", bold: "/F2", mono: "/F3"}[font]
    ["BT ", face, " ", num(size), " Tf ", num(x), " ", num(y), " Td (", escape(text), ") Tj ET\n"]
  end

  defp rule(y, w),
    do: [
      "0.067 0.067 0.067 RG ",
      num(w),
      " w ",
      num(@margin),
      " ",
      num(y),
      " m ",
      num(@page_w - @margin),
      " ",
      num(y),
      " l S\n"
    ]

  defp num(n) when is_integer(n), do: Integer.to_string(n)
  defp num(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  @win_ansi %{
    0x2018 => 0x91,
    0x2019 => 0x92,
    0x201C => 0x93,
    0x201D => 0x94,
    0x2022 => 0x95,
    0x2013 => 0x96,
    0x2014 => 0x97,
    0x2026 => 0x85,
    0x20AC => 0x80
  }

  # PDF string bytes in WinAnsiEncoding, with ( ) \ escaped.
  defp escape(text) do
    for <<c::utf8 <- text>>, into: "" do
      case c do
        ?( -> "\\("
        ?) -> "\\)"
        ?\\ -> "\\\\"
        c when c in 32..126 or c in 0xA0..0xFF -> <<c>>
        c -> <<Map.get(@win_ansi, c, ??)>>
      end
    end
  end

  ## The file

  defp document(streams, title) do
    fonts = [
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"
    ]

    # 1 catalog, 2 pages, 3-5 fonts, 6 info, then a page and its content each.
    first = 7
    page_ids = for i <- 0..(length(streams) - 1), do: first + 2 * i
    kids = Enum.map_join(page_ids, " ", &"#{&1} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{kids}] /Count #{length(streams)} >>"
      ] ++
        fonts ++
        [
          "<< /Title (#{escape(title)}) /Producer (AI in Practice #{escape(Version.code_version())}) >>"
        ] ++
        Enum.flat_map(Enum.zip(page_ids, streams), fn {id, stream} ->
          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{@page_w} #{@page_h}] " <>
              "/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents #{id + 1} 0 R >>",
            "<< /Length #{byte_size(stream)} >>\nstream\n" <> stream <> "\nendstream"
          ]
        end)

    header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({header, []}, fn {object, n}, {acc, offsets} ->
        {acc <> "#{n} 0 obj\n" <> object <> "\nendobj\n", [byte_size(acc) | offsets]}
      end)

    xref_at = byte_size(body)

    entries =
      offsets
      |> Enum.reverse()
      |> Enum.map(&(String.pad_leading("#{&1}", 10, "0") <> " 00000 n \n"))

    body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      Enum.join(entries) <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R /Info 6 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
  end
end
