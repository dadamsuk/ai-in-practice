defmodule AiInPractice.Reports.PDF do
  @moduledoc """
  Both reports as A4 PDFs in the printed-specification register (PRD §9,
  §13.2; #706), rendered with Typst (the spike, #705) from
  `priv/reports/report.typ`.

  The content is `AiInPractice.Reports.Content`, the same blocks the
  reports screen shows, so the person downloads exactly what they reviewed.
  It reaches Typst as an in-memory JSON file, never spliced into markup, so
  nothing a person typed can be read as Typst. Every page has a running
  head and a running foot with the role group, date and versions; every
  page of the assessor report also carries the standing statement.

  The assessor PDF has the signed envelope (`AiInPractice.Reports.Signing`)
  attached, holding `AiInPractice.Reports.Payload`. `attachment/2` reads it
  back out.

  PDFs are made on demand, in memory, and never stored (PRD §10). The Typst
  NIF compiles in memory too: nothing touches disk.
  """

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Reports.{Content, Payload, Signing}
  alias AiInPractice.{RoleGroups, Version}

  @template_path Path.join([__DIR__, "..", "..", "..", "priv", "reports", "report.typ"])
  @external_resource @template_path
  @template File.read!(@template_path)

  @doc """
  The PDF of the `:candidate` or `:assessor` report, as a binary.
  `meta` is as `AiInPractice.Reports.Content.meta/0`. The assessor PDF is
  signed with `keyring` (the configured one by default).
  """
  @spec render(:candidate | :assessor, Report.t(), Content.meta(), Signing.keyring() | nil) ::
          binary()
  def render(audience, report, meta, keyring \\ nil)

  def render(audience, %Report{} = report, meta, keyring)
      when audience in [:candidate, :assessor] do
    {blocks, assets} =
      case audience do
        :candidate ->
          {Content.candidate(report), []}

        :assessor ->
          envelope =
            Signing.envelope(Payload.assessor(report, meta), keyring || Signing.keyring())

          {Content.assessor(report), [{"signed.json", envelope}]}
      end

    content = %{
      document_title: "AI in Practice: #{String.downcase(Content.title(audience))}",
      title: Content.title(audience),
      title_short: String.downcase(Content.title(audience)),
      facts: for({label, value} <- Content.header(meta), do: [label, value]),
      statement: if(audience == :assessor, do: Content.statement()),
      foot: foot(meta),
      blocks: Enum.map(blocks, &block/1),
      signed: audience == :assessor,
      attachment: Signing.attachment_name(),
      check_at: AiInPracticeWeb.Endpoint.url() <> "/check"
    }

    opts = [
      assets: [{"content.json", Jason.encode!(content)} | assets],
      extra_fonts: [fonts_dir()]
    ]

    case Typst.render_to_pdf(@template, [], opts) do
      {:ok, pdf} -> pdf
      # Typst's message is not repeated: a report's words must never reach
      # a log or a crash report (PRD §10).
      {:error, _reason} -> raise "could not render the #{audience} report PDF"
    end
  end

  @doc "The file name a report downloads as."
  @spec filename(:candidate | :assessor) :: String.t()
  def filename(:candidate), do: "ai-in-practice-your-report.pdf"
  def filename(:assessor), do: "ai-in-practice-assessor-report.pdf"

  defp fonts_dir, do: Application.app_dir(:ai_in_practice, "priv/fonts")

  defp foot(meta) do
    Enum.join(
      [
        RoleGroups.name(meta.role_group),
        Date.to_iso8601(meta.date),
        "code #{Version.code_version()}",
        "rubric v#{Version.rubric_version()}",
        "model #{Version.model()}"
      ],
      " · "
    )
  end

  defp block({:labelled, label, text}), do: %{kind: "labelled", label: label, text: text}
  defp block({:list, items}), do: %{kind: "list", items: items}

  defp block({:reading, item}),
    do: %{kind: "reading", title: item.title, url: item.url, note: item.note}

  defp block({kind, text}), do: %{kind: Atom.to_string(kind), text: text}

  ## Reading attachments back

  @doc """
  The bytes of the file attached to `pdf` under `name`, or `:error`.

  Reads the PDFs this module writes: a file specification naming `name`,
  whose embedded file stream is plain or Flate-compressed. It is not a
  general PDF parser.
  """
  @spec attachment(binary(), String.t()) :: {:ok, binary()} | :error
  def attachment(pdf, name) when is_binary(pdf) and is_binary(name) do
    spec = ~r{/Type\s*/Filespec[^>]*?/F\s*\(#{Regex.escape(name)}\)}

    with [{at, _}] <- Regex.run(spec, pdf, return: :index),
         [_, ref] <- Regex.run(~r{/EF\s*<<\s*/F\s+(\d+)\s+0\s+R}, binary_part_from(pdf, at)),
         {:ok, dict, data} <- stream_object(pdf, ref) do
      decode(dict, data)
    else
      _ -> :error
    end
  end

  defp binary_part_from(bin, at), do: binary_part(bin, at, min(byte_size(bin) - at, 2048))

  defp stream_object(pdf, ref) do
    with [{at, len}] <- Regex.run(~r{(?<![0-9])#{ref}\s+0\s+obj\s*}, pdf, return: :index),
         rest = binary_part(pdf, at + len, byte_size(pdf) - at - len),
         [{dict_end, _}] <- Regex.run(~r{>>\s*stream\r?\n}, rest, return: :index),
         [{start, start_len}] <- Regex.run(~r{stream\r?\n}, rest, return: :index),
         dict = binary_part(rest, 0, dict_end),
         [_, length] <- Regex.run(~r{/Length\s+(\d+)(?!\s+\d+\s+R)}, dict),
         length = String.to_integer(length),
         true <- start + start_len + length <= byte_size(rest) do
      {:ok, dict, binary_part(rest, start + start_len, length)}
    else
      _ -> :error
    end
  end

  defp decode(dict, data) do
    if dict =~ "/FlateDecode" do
      try do
        {:ok, :zlib.uncompress(data)}
      rescue
        ErlangError -> :error
      end
    else
      {:ok, data}
    end
  end
end
