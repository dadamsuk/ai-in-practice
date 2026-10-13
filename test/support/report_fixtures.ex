defmodule AiInPractice.ReportFixtures do
  @moduledoc "Validated reports for tests, built from the fake model's payload."

  alias AiInPractice.Assessment.{Report, Transcript}
  alias AiInPractice.LLM.Fake

  @doc "A report quoting `answers`; `changes` are merged into the payload first."
  def report_fixture(
        answers \\ ["I used AI to draft the quarterly pricing paper."],
        changes \\ %{}
      ) do
    transcript =
      Enum.reduce(answers, %Transcript{}, fn answer, t ->
        t |> Transcript.ask("Q?", :main) |> Transcript.answer(answer)
      end)

    reading_ids = Map.get(changes, "reading_picks", [])
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
end
