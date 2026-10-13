defmodule AiInPractice.Eval.QuestionsTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Eval.Questions

  defp entry(question, kind \\ :main, answer \\ "No."),
    do: %{question: question, kind: kind, answer: answer}

  test "guidance/0 reads every guidance question from the rubric, without role markers" do
    guidance = Questions.guidance()
    assert length(guidance) >= 10
    assert "What they tried and stopped using, and why." in guidance
    refute Enum.any?(guidance, &String.starts_with?(&1, ["-", "*"]))
  end

  describe "measure/1" do
    test "counts questions, follow-ups and back-to-back follow-ups" do
      m =
        Questions.measure([
          entry("Q one?"),
          entry("Q two?", :follow_up),
          entry("Q three?", :follow_up),
          entry("Q four?"),
          entry("Q five?", :follow_up)
        ])

      assert %{questions: 5, follow_ups: 3, consecutive_follow_ups: 1} = m
    end

    test "grounded: later questions reusing two distinctive words from earlier answers" do
      m =
        Questions.measure([
          entry(
            "What did you last use it for?",
            :main,
            "We automated invoice matching in payables."
          ),
          # reuses "invoice" and "matching"
          entry("How did the invoice matching go?"),
          # reuses only "invoice"
          entry("Who owns invoice approvals?"),
          # common question words do not count
          entry("Could you describe something specific about that?")
        ])

      assert_in_delta m.grounded, 1 / 3, 1.0e-9
    end

    test "grounded is nil with one question or none; no answers means nothing to build on" do
      assert Questions.measure([entry("Only one?")]).grounded == nil
      assert Questions.measure([]).grounded == nil

      assert Questions.measure([entry("First?", :main, nil), entry("Second about matching?")]).grounded ==
               0.0
    end

    test "near_script counts questions close to a guidance question" do
      m =
        Questions.measure([
          entry("What have you tried and stopped using, and why?"),
          entry("How do the warehouse rotas get planned on a Monday?")
        ])

      assert m.near_script == 1
    end

    test "level_leaks counts questions naming a level or a score" do
      m =
        Questions.measure([
          entry("So far I would place you at Advanced. What else?"),
          entry("You're at a 7/10 on this. Anything to add?"),
          entry("What advanced features of the tool did your team use?")
        ])

      assert m.level_leaks == 2
    end
  end

  test "near_script?/1" do
    assert Questions.near_script?("What have you tried and stopped using, and why?")
    refute Questions.near_script?("Which supplier contract did the pilot change?")
  end

  test "distinctive/1 ignores short and common words and apostrophes" do
    assert Questions.distinctive("You've mentioned the Sheffield ledger, haven't you? Really.") ==
             MapSet.new(~w(sheffield ledger havent))

    assert Questions.distinctive(nil) == MapSet.new()
  end

  test "aggregate/1 sums counts and averages per run and grounded share" do
    a = %{
      questions: 10,
      follow_ups: 2,
      consecutive_follow_ups: 0,
      grounded: 0.5,
      near_script: 1,
      level_leaks: 0
    }

    b = %{
      a
      | questions: 14,
        follow_ups: 1,
        consecutive_follow_ups: 1,
        grounded: nil,
        near_script: 0,
        level_leaks: 1
    }

    c = %{a | grounded: 1.0}

    assert Questions.aggregate([a, b, c]) == %{
             runs: 3,
             questions: 34,
             questions_per_run: 34 / 3,
             follow_ups: 5,
             consecutive_follow_ups: 1,
             grounded: 0.75,
             near_script: 2,
             level_leaks: 1
           }

    assert %{runs: 0, questions_per_run: nil, grounded: nil} = Questions.aggregate([])
  end
end
