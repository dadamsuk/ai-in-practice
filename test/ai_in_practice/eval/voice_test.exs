defmodule AiInPractice.Eval.VoiceTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Eval.{Summary, Voice}

  defp report(overall, description \\ "They gave one example.") do
    %{
      summary: "They use AI for drafting.",
      overall: overall,
      areas: [%{area: :understanding, description: description}]
    }
  end

  test "third person passes" do
    assert Voice.second_person(report("Their profile is uneven. They lead on checking.")) == []
  end

  test ~s("you" or "your" in a shared field is caught, by field, whatever the case) do
    assert Voice.second_person(report("Your profile is uneven.")) == ["overall"]
    assert Voice.second_person(report("They check. YOU should too.")) == ["overall"]

    assert Voice.second_person(report("They check.", "You described one case.")) ==
             ["understanding description"]

    both = %{report("This profile is uneven. Yours is not.") | summary: "You use AI."}
    assert Voice.second_person(both) == ["summary", "overall"]
  end

  test "the person's own words in quotation marks are skipped" do
    assert Voice.second_person(report(~s(They said "you have to check it" and do.))) == []
    assert Voice.second_person(report("They said “your numbers first” and mean it.")) == []

    assert Voice.second_person(report(~s(They said "check it", and your view differs.))) == [
             "overall"
           ]
  end

  test "only whole words count" do
    assert Voice.second_person(report("Their youth programme and a bayou depot.")) == []
  end

  test "candidate-only and assessor-only fields are not checked" do
    r =
      Map.merge(report("They check."), %{
        main_gap: "Your gap is X.",
        assessor_next_steps: ["Ask you"]
      })

    assert Voice.second_person(r) == []
  end

  test "reads the string keys of a run's JSON too, and tolerates missing parts" do
    assert Voice.second_person(%{
             "overall" => "Your profile.",
             "areas" => [%{"area" => "attitude", "description" => "You are open."}]
           }) ==
             ["overall", "attitude description"]

    assert Voice.second_person(%{}) == []
    assert Voice.second_person(%{overall: nil, areas: [nil, %{area: :attitude}]}) == []
  end

  test "aggregate counts reports, not fields, and lists the fields once" do
    reports = [
      report("Your profile is uneven.", "You gave one."),
      report("Your view is clear."),
      report("Their profile is even.")
    ]

    assert Voice.aggregate(reports) == %{
             reports: 3,
             second_person: 2,
             third_person: 0,
             fields: ["overall", "understanding description"]
           }

    assert Voice.aggregate([]) == %{reports: 0, second_person: 0, third_person: 0, fields: []}
  end

  test ~s(the person's own text that talks about them as "they" is caught, by field) do
    good = %{
      your_summary: "You use AI for drafting.",
      your_overall:
        "Your profile is uneven. Your team follows your lead, and they ask you first.",
      areas: [%{area: :attitude, your_description: "You are open to it."}]
    }

    assert Voice.third_person(good) == []

    bad = %{
      good
      | your_summary: "They use AI for drafting.",
        areas: [%{area: :attitude, your_description: "This person is open to it."}]
    }

    assert Voice.third_person(bad) == ["your_summary", "attitude your_description"]
    assert Voice.third_person(%{"your_overall" => "Their profile is uneven."}) == ["your_overall"]
    assert Voice.third_person(%{your_overall: ~s(You said "They never check it.")}) == []

    assert %{
             second_person: 0,
             third_person: 1,
             fields: ["attitude your_description", "your_summary"]
           } =
             Voice.aggregate([bad, good])
  end

  test "the summary says how many reports slipped, and where" do
    summary = %{
      personas: [],
      pairs: [],
      totals: %{runs: 3, reports: 3, first_pass: 3, calls: 9, cost: 0.0, tripped: false},
      latency: %{question_ms: nil, report_ms: nil},
      cost_per_report: nil,
      questions: %{runs: 0},
      rejections: %{},
      calls: %{},
      voice: %{reports: 3, second_person: 2, third_person: 0, fields: ["overall"]}
    }

    assert Summary.markdown(summary, %{}) =~
             ~s{Voice: 2 of 3 reports said "you" in the assessor's text (overall)}

    both =
      put_in(summary.voice, %{
        reports: 3,
        second_person: 1,
        third_person: 1,
        fields: ["overall", "your_summary"]
      })

    assert Summary.markdown(both, %{}) =~
             ~s{Voice: 1 of 3 reports said "you" in the assessor's text; 1 of 3 reports said "they" in the person's own text (overall, your_summary)}

    clean = put_in(summary.voice, %{reports: 3, second_person: 0, third_person: 0, fields: []})
    assert Summary.markdown(clean, %{}) =~ "Voice: no report of 3 broke its perspective"

    assert Summary.markdown(Map.delete(summary, :voice), %{}) =~ "Voice: n/a"
  end
end
