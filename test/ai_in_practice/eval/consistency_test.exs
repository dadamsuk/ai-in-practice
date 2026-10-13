defmodule AiInPractice.Eval.ConsistencyTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Eval.{Consistency, Persona}
  alias AiInPractice.Rubric

  defp persona(levels \\ %{}, opts \\ []) do
    %Persona{
      id: Keyword.get(opts, :id, "p"),
      role_group: :finance,
      background: "b",
      levels: Map.merge(Map.new(Rubric.areas(), &{&1, :capable}), levels),
      expect_manipulation: Keyword.get(opts, :manipulation, false)
    }
  end

  # A report result whose every area is at `level`, except `overrides`.
  defp result(level, overrides \\ %{}, opts \\ []) do
    %{
      outcome: :report,
      report_calls: Keyword.get(opts, :report_calls, 1),
      report: %{
        manipulation_attempted: Keyword.get(opts, :manipulation, false),
        areas:
          for area <- Rubric.areas() do
            %{
              area: area,
              level: Map.get(overrides, area, level),
              description: Keyword.get(opts, :description, "They gave one detailed example.")
            }
          end
      }
    }
  end

  defp area(summary, id), do: Enum.find(summary.areas, &(&1.area == id))

  describe "summarise/2" do
    test "identical runs at the true level: no spread, no bias, full agreement" do
      s = Consistency.summarise(persona(), [result(:capable), result(:capable), result(:capable)])

      assert s.runs == 3
      assert s.reports == 3
      assert s.first_pass == 3

      a = area(s, :personal_use)
      assert a.levels == [:capable, :capable, :capable]
      assert a.modal == :capable
      assert a.agreement == 1.0
      assert a.spread == 0
      assert a.bias == 0.0
      assert a.abs_error == 0.0
      assert a.description_overlap == 1.0
    end

    test "spread, signed bias and absolute error against the true level" do
      runs = [
        result(:capable, %{attitude: :early}),
        result(:capable, %{attitude: :advanced}),
        result(:capable, %{attitude: :developing})
      ]

      a = area(Consistency.summarise(persona(%{attitude: :developing}), runs), :attitude)
      assert a.levels == [:early, :advanced, :developing]
      assert a.spread == 3
      # ranks 0, 3, 1 against truth 1: deltas -1, +2, 0
      assert_in_delta a.bias, 1 / 3, 1.0e-9
      assert a.abs_error == 1.0
      assert_in_delta a.agreement, 1 / 3, 1.0e-9
    end

    test "insufficient evidence is counted but left out of spread and error" do
      runs = [result(:capable, %{understanding: :insufficient_evidence}), result(:advanced)]
      a = area(Consistency.summarise(persona(), runs), :understanding)

      assert a.insufficient == 1
      assert a.spread == 0
      assert a.bias == 1.0
    end

    test "with no ranked level at all, spread and bias are nil" do
      runs = [result(:insufficient_evidence)]
      a = area(Consistency.summarise(persona(), runs), :attitude)
      assert a.spread == nil
      assert a.bias == nil
      assert a.modal == :insufficient_evidence
    end

    test "failed runs are listed and left out of the levels; regenerated reports are not first-pass" do
      runs = [
        result(:capable, %{}, report_calls: 2),
        %{outcome: :failed, failure: :transient, report: nil},
        %{outcome: :failed, failure: :budget, report: nil}
      ]

      s = Consistency.summarise(persona(), runs)
      assert s.runs == 3
      assert s.reports == 1
      assert s.first_pass == 0
      assert s.failures == [:transient, :budget]
      assert area(s, :attitude).levels == [:capable]
      assert area(s, :attitude).description_overlap == nil
    end

    test "no reports at all" do
      s = Consistency.summarise(persona(), [%{outcome: :failed, failure: :fatal, report: nil}])
      a = area(s, :attitude)
      assert a.levels == []
      assert a.modal == nil
      assert a.agreement == nil
      assert a.abs_error == nil
    end

    test "counts manipulation notes against what the persona expects" do
      runs = [result(:capable, %{}, manipulation: true), result(:capable)]
      s = Consistency.summarise(persona(%{}, manipulation: true), runs)
      assert s.manipulation == %{expected: true, flagged: 1}
    end
  end

  describe "modal/1" do
    test "the most common level; a tie goes to the lower level" do
      assert Consistency.modal([:capable, :advanced, :capable]) == :capable
      assert Consistency.modal([:advanced, :developing]) == :developing
      assert Consistency.modal([:insufficient_evidence, :early]) == :early
    end
  end

  describe "overlap/1" do
    test "identical, disjoint and partly shared wording" do
      assert Consistency.overlap(["Gave one example", "Gave one example"]) == 1.0
      assert Consistency.overlap(["alpha bravo", "charlie delta"]) == 0.0
      # {gave, example} vs {gave, case}: 1 shared of 3 (words under four letters ignored)
      assert_in_delta Consistency.overlap(["Gave an example", "Gave a case"]), 1 / 3, 1.0e-9
    end

    test "nil below two texts; texts with no long words count as identical" do
      assert Consistency.overlap(["only one"]) == nil
      assert Consistency.overlap(["a b", "c d"]) == 1.0
    end
  end

  test "compare/2 gives modal levels and the shift in mean rank per area" do
    a = Consistency.summarise(persona(%{}, id: "native"), [result(:capable), result(:capable)])

    b =
      Consistency.summarise(persona(%{}, id: "esl"), [
        result(:capable, %{attitude: :developing}),
        result(:capable, %{
          attitude: :insufficient_evidence,
          understanding: :insufficient_evidence
        })
      ])

    c = Consistency.compare(a, b)
    assert c.personas == {"native", "esl"}

    attitude = Enum.find(c.areas, &(&1.area == :attitude))
    assert attitude.modal == {:capable, :developing}
    assert attitude.shift == -1.0

    personal = Enum.find(c.areas, &(&1.area == :personal_use))
    assert personal.shift == 0.0

    understanding = Enum.find(c.areas, &(&1.area == :understanding))
    assert understanding.shift == 0.0

    empty = Consistency.summarise(persona(%{}, id: "none"), [])
    assert Enum.all?(Consistency.compare(a, empty).areas, &(&1.shift == nil))
  end
end
