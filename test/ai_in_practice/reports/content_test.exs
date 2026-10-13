defmodule AiInPractice.Reports.ContentTest do
  use AiInPractice.DataCase, async: true

  import AiInPractice.ReportFixtures

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Reading
  alias AiInPractice.Reports.{Content, Payload}

  defp headings(blocks), do: for({:h2, text} <- blocks, do: text)

  test "the candidate report has every section the rubric asks for, in order" do
    blocks = Content.candidate(report_fixture())

    assert headings(blocks) == [
             "Summary",
             "The five areas",
             "What you are doing well",
             "The main gap",
             "Next steps",
             "What the assessor report contains"
           ]

    texts = Content.texts(blocks)
    assert "In the next two weeks" in texts
    assert "how you will know it helped" in texts
    assert "After that" in texts

    for area <- AiInPractice.Rubric.areas(),
        do: assert({:h3, AiInPractice.Rubric.area_name(area)} in blocks)
  end

  test "the assessor report opens on its statement and has quotes, strong answers and questions" do
    blocks = Content.assessor(report_fixture())

    assert [{:statement, statement} | _] = blocks
    assert statement =~ "conversation starter"
    assert statement =~ "has not been checked"
    assert statement =~ "one input to human judgement"

    assert headings(blocks) == [
             "Summary",
             "The five areas",
             "What to explore next",
             "Questions to ask in person"
           ]

    assert {:quote, "I used AI to draft the quarterly pricing"} in blocks
    texts = Content.texts(blocks)
    assert "a strong answer for this role would include" in texts
    assert "where this one fell short" in texts
    assert "listen for" in texts
    # The candidate's own next steps and reading stay private.
    refute "In the next two weeks" in texts
    refute "Further reading" in texts
  end

  test "never shows an area's internal level or confidence" do
    report = report_fixture()
    assert Enum.all?(report.areas, &(&1.level == :developing and &1.confidence == :medium))

    for blocks <- [Content.candidate(report), Content.assessor(report)] do
      text = blocks |> Content.texts() |> Enum.join(" ")
      refute text =~ ~r/\b(developing|capable|advanced|early|insufficient)\b/i
      refute text =~ ~r/\bmedium\b/i
      refute Enum.any?(Report.leaks(report))
    end
  end

  test "the manipulation note appears on the assessor report only when needed" do
    plain = Content.assessor(report_fixture())
    refute {:strong, Report.manipulation_note()} in plain

    flagged = Content.assessor(report_fixture(["One."], %{"manipulation_attempted" => true}))
    assert {:strong, Report.manipulation_note()} in flagged
    refute Report.manipulation_note() in Content.texts(Content.candidate(report_fixture()))
  end

  test "reading picks become entries from the list; with none, there is no reading section" do
    {:ok, item} =
      Reading.create_item(%{
        title: "Working with AI",
        url: "https://example.com/working",
        areas: [:personal_use],
        note: "Short and practical."
      })

    blocks = Content.candidate(report_fixture(["One."], %{"reading_picks" => [item.id]}))
    assert "Resources for your next steps" in headings(blocks)

    assert {:reading,
            %{
              title: "Working with AI",
              url: "https://example.com/working",
              meta: nil,
              why: nil,
              note: "Short and practical."
            }} in blocks

    refute "Resources for your next steps" in headings(Content.candidate(report_fixture()))

    refute "Resources for your next steps" in headings(
             Content.assessor(report_fixture(["One."], %{"reading_picks" => [item.id]}))
           )
  end

  test "a library resource shows its facts in lower case, and why it was chosen" do
    {:ok, item} =
      Reading.create_item(%{
        title: "How I use LLMs",
        url: "https://example.com/llms",
        areas: [:personal_use],
        note: "Two hours of real daily use.",
        author: "Andrej Karpathy, 2025",
        format: "Video",
        cost: "Free to audit"
      })

    picks = [%{"id" => item.id, "why" => "You said you want to try voice and research modes."}]
    blocks = Content.candidate(report_fixture(["One."], %{"reading_picks" => picks}))

    assert {:reading,
            %{
              title: "How I use LLMs",
              url: "https://example.com/llms",
              meta: "Andrej Karpathy, 2025 · video · free to audit",
              why: "You said you want to try voice and research modes.",
              note: "Two hours of real daily use."
            }} in blocks

    texts = Content.texts(blocks)
    assert "You said you want to try voice and research modes." in texts
    assert "Andrej Karpathy, 2025 · video · free to audit" in texts
  end

  test "the note on the assessor report says it leaves out next steps and resources" do
    texts = Content.texts(Content.candidate(report_fixture()))
    assert Enum.any?(texts, &(&1 =~ "does not include this report's next steps or resources"))
  end

  test "a reading pick removed from the list since is skipped" do
    {:ok, item} =
      Reading.create_item(%{title: "Gone", url: "https://example.com/g", areas: [:attitude]})

    report = report_fixture(["One."], %{"reading_picks" => [item.id]})
    {:ok, _} = Reading.delete_item(item)
    refute "Resources for your next steps" in headings(Content.candidate(report))
  end

  test "the header names the role group, date, mode and kind of link, in words" do
    assert Content.header(meta_fixture()) == [
             {"role group", "Finance"},
             {"date", "13 October 2026"},
             {"answers", "typed"},
             {"link", "from a recruiter"}
           ]

    assert {"link", "individual"} in Content.header(meta_fixture(%{link_kind: :individual}))
    assert {"answers", "spoken"} in Content.header(meta_fixture(%{mode: :voice}))
  end

  test "a sample report says so first in its header; a real one never does" do
    assert [{"sample", "a fictional person, made up for illustration"} | rest] =
             Content.header(meta_fixture(%{sample: true}))

    assert rest == Content.header(meta_fixture())
    assert Content.header(meta_fixture(%{sample: false})) == Content.header(meta_fixture())
    refute Enum.any?(Content.header(meta_fixture()), &match?({"sample", _}, &1))
  end

  test "a quick session's report says so last in its header; a full one never does" do
    full = Content.header(meta_fixture())
    quick = Content.header(meta_fixture(%{quick: true}))

    assert quick == full ++ [{"session", Content.quick()}]
    assert Content.header(meta_fixture(%{quick: false})) == full
    assert Content.quick() =~ "not a full conversation"
  end

  test "the check page shows the quick marker from the signed content" do
    payload = report_fixture() |> Payload.assessor(meta_fixture(%{quick: true}))
    payload = payload |> Jason.encode!() |> Jason.decode!()
    assert {"session", Content.quick()} in Content.signed_header(payload)

    full =
      report_fixture() |> Payload.assessor(meta_fixture()) |> Jason.encode!() |> Jason.decode!()

    refute Enum.any?(Content.signed_header(full), &match?({"session", _}, &1))
  end

  describe "signed content (the check page)" do
    # As the check page gets it: decoded from the signed JSON.
    defp signed(report, meta \\ meta_fixture()),
      do: report |> Payload.assessor(meta) |> Jason.encode!() |> Jason.decode!()

    test "a signed payload lays out exactly as the assessor report it came from" do
      report = report_fixture(["One answer.", "Another answer."])
      assert Content.signed_blocks(signed(report)) == Content.assessor(report)

      flagged = report_fixture(["One."], %{"manipulation_attempted" => true})
      assert Content.signed_blocks(signed(flagged)) == Content.assessor(flagged)
    end

    test "the signed header matches the report's header" do
      for meta <- [
            meta_fixture(),
            meta_fixture(%{link_kind: :individual, mode: :voice}),
            meta_fixture(%{sample: true})
          ] do
        assert Content.signed_header(signed(report_fixture(), meta)) == Content.header(meta)
      end
    end

    test "a sample marker that is not text is not shown" do
      payload = signed(report_fixture()) |> Map.put("sample", true)
      assert Content.signed_header(payload) == Content.header(meta_fixture())
    end

    test "empty or missing parts are left out rather than shown blank" do
      payload = %{
        "statement" => Content.statement(),
        "summary" => " ",
        "date" => "not a date",
        "areas" => [%{"name" => "Understanding", "quotes" => nil, "shortfall" => ""}],
        "follow_up_questions" => [%{"question" => "Why?", "listen_for" => nil}]
      }

      blocks = Content.signed_blocks(payload)

      assert blocks == [
               {:statement, Content.statement()},
               {:h2, "Summary"},
               {:h2, "The five areas"},
               {:h3, "Understanding"},
               {:h2, "What to explore next"},
               {:list, []},
               {:h2, "Questions to ask in person"},
               {:strong, "Why?"}
             ]

      assert {"date", "not a date"} in Content.signed_header(payload)
    end
  end
end
