defmodule AiInPractice.ReportFixtures do
  @moduledoc "Validated reports for tests, built from the fake model's payload."

  alias AiInPractice.Assessment.{Report, Transcript}
  alias AiInPractice.LLM.Fake
  alias AiInPractice.Reports.{PDF, Signing}

  @doc "A report quoting `answers`; `changes` are merged into the payload first."
  def report_fixture(
        answers \\ ["I used AI to draft the quarterly pricing paper."],
        changes \\ %{}
      ) do
    transcript =
      Enum.reduce(answers, %Transcript{}, fn answer, t ->
        t |> Transcript.ask("Q?", :main) |> Transcript.answer(answer)
      end)

    reading_ids =
      changes |> Map.get("reading_picks", []) |> Enum.map(&if(is_map(&1), do: &1["id"], else: &1))

    payload = answers |> Fake.report(reading_ids) |> Map.merge(changes)
    {:ok, report} = Report.validate(payload, :finance, transcript, reading_ids)
    report
  end

  def meta_fixture(attrs \\ %{}) do
    Map.merge(
      %{link_kind: :candidate, role_group: :finance, mode: :text, date: ~D[2026-10-13]},
      attrs
    )
  end

  @doc """
  The assessor PDF with its embedded envelope edited by `fun`, written back
  as a Flate stream (cross-reference offsets are not fixed: the reader does
  not use them).
  """
  def edit_envelope(pdf, fun) do
    {:ok, envelope} = PDF.attachment(pdf, Signing.attachment_name())
    edited = fun.(envelope)
    if edited == envelope, do: raise(ArgumentError, "the edit changed nothing")
    data = :zlib.compress(edited)

    [{at, len}, {length_at, length_len}] =
      Regex.run(~r{<</Length (\d+)/Type/EmbeddedFile.*?>>\nstream\n}s, pdf, return: :index)

    old_length = pdf |> binary_part(length_at, length_len) |> String.to_integer()

    dict =
      pdf |> binary_part(at, len) |> String.replace(~r{/Length \d+}, "/Length #{byte_size(data)}")

    dict =
      if dict =~ "/FlateDecode",
        do: dict,
        else: String.replace(dict, "/Type/EmbeddedFile", "/Type/EmbeddedFile/Filter/FlateDecode")

    tail_at = at + len + old_length

    binary_part(pdf, 0, at) <> dict <> data <> binary_part(pdf, tail_at, byte_size(pdf) - tail_at)
  end
end
