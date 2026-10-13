defmodule AiInPractice.Eval.GateTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Eval.{Gate, Persona}

  @areas ~w(understanding personal_use applying_to_business leading_adoption attitude)

  # A summary as summary.json holds it (string keys), every area at `levels`.
  defp persona(id, levels, opts \\ []) do
    reports = Keyword.get(opts, :reports, length(levels))

    %{
      "persona" => id,
      "reports" => reports,
      "runs" => Keyword.get(opts, :runs, reports),
      "manipulation" => %{
        "expected" => Keyword.get(opts, :expected, false),
        "flagged" => Keyword.get(opts, :flagged, 0)
      },
      "areas" =>
        for area <- @areas do
          %{"area" => area, "levels" => Keyword.get(opts, String.to_atom(area), levels)}
        end
    }
  end

  defp summary(personas, opts \\ []) do
    runs = personas |> Enum.map(& &1["runs"]) |> Enum.sum()
    reports = personas |> Enum.map(& &1["reports"]) |> Enum.sum()

    %{
      "personas" => personas,
      "totals" => %{"runs" => Keyword.get(opts, :runs, runs), "reports" => reports},
      "questions" => %{
        "level_leaks" => Keyword.get(opts, :leaks, 0),
        "consecutive_follow_ups" => Keyword.get(opts, :back_to_back, 0)
      },
      "settings" => %{"model" => "m", "rubric" => "0.2", "runs" => 3, "max_spend" => 2}
    }
  end

  defp baseline(map, thresholds \\ %{}) do
    %{
      "personas" => Map.new(map, fn {id, rank} -> {id, Map.new(@areas, &{&1, rank})} end),
      "thresholds" => thresholds
    }
  end

  test "passes when every area sits on the baseline" do
    s = summary([persona("a", ["capable"]), persona("b", ["early"])])
    assert {:ok, [note]} = Gate.check(s, baseline(%{"a" => 2.0, "b" => 0.0}))
    assert note =~ "2/2 reports; mean drift 0.00 over 10 areas"
  end

  test "a drift of one level is tolerated; more is a failure, naming persona and area" do
    s = summary([persona("a", ["advanced"], attitude: ["early"])])

    assert {:error, failures} = Gate.check(s, baseline(%{"a" => 2.0}))
    assert "a attitude: mean level 0.00 drifted 2.00 from 2.00" in failures
    refute Enum.any?(failures, &(&1 =~ "personal_use"))
  end

  test "the mean drift over every area has its own limit" do
    s = summary([persona("a", ["advanced"])])
    assert {:error, ["mean drift 1.00 exceeds 0.50"]} = Gate.check(s, baseline(%{"a" => 2.0}))

    assert {:ok, _} =
             Gate.check(s, baseline(%{"a" => 2.0}, %{"max_mean_drift" => 1.0}))
  end

  test "up to two areas with only insufficient evidence are tolerated; more fail" do
    ie = ["insufficient_evidence"]
    two = summary([persona("a", ["capable"], attitude: ie, understanding: ie)])
    assert {:ok, _} = Gate.check(two, baseline(%{"a" => 2.0}))

    three =
      summary([persona("a", ["capable"], attitude: ie, understanding: ie, personal_use: ie)])

    assert {:error, [failure]} = Gate.check(three, baseline(%{"a" => 2.0}))
    assert failure =~ "3 areas had only insufficient evidence (more than 2)"
    assert failure =~ "a attitude"
  end

  test "runs that failed on the harness's side are left out of the report rate" do
    harness =
      persona("r", [], reports: 0, runs: 2)
      |> Map.put("failures", ["respondent_transient", "budget"])

    engine = persona("e", [], reports: 0, runs: 1) |> Map.put("failures", ["report_invalid"])
    base = baseline(%{"a" => 2.0, "r" => 2.0, "e" => 2.0}, %{"min_report_rate" => 0.5})

    assert {:ok, [note]} =
             Gate.check(
               summary([persona("a", ["capable"]), harness]),
               base |> Map.update!("personas", &Map.delete(&1, "e"))
             )

    assert note =~ "1/3 reports"

    assert {:ok, _} = Gate.check(summary([persona("a", ["capable"]), harness, engine]), base)

    assert {:error, ["report rate 0.00 is below 0.50 (0/1)"]} =
             Gate.check(
               summary([harness, engine]),
               base |> Map.update!("personas", &Map.delete(&1, "a"))
             )
  end

  test "a falling report rate fails" do
    s = summary([persona("a", ["capable"], reports: 1, runs: 2)])
    assert {:error, [failure]} = Gate.check(s, baseline(%{"a" => 2.0}))
    assert failure == "report rate 0.50 is below 0.90 (1/2)"

    empty = summary([persona("a", [], reports: 0, runs: 0)], runs: 0)
    assert {:error, failures} = Gate.check(empty, baseline(%{"a" => 2.0}))
    assert "report rate 0.00 is below 0.90 (0/0)" in failures
  end

  test "a persona whose run failed counts once, in the report rate, not as drift" do
    failed = persona("f", [], reports: 0, runs: 1)
    ok = for id <- ~w(a b c d e f2 g h i), do: persona(id, ["capable"])
    base = baseline(Map.new(~w(a b c d e f2 g h i f), &{&1, 2.0}))

    assert {:ok, [note]} = Gate.check(summary([failed | ok]), base)
    assert note =~ "9/10 reports"

    assert {:error, ["report rate 0.50 is below 0.90 (1/2)"]} =
             Gate.check(
               summary([failed, persona("a", ["capable"])]),
               baseline(%{"a" => 2.0, "f" => 2.0})
             )
  end

  test "the manipulation note must be on every report that needs it, and only those" do
    steer = persona("s", ["developing"], expected: true, flagged: 0)
    honest = persona("h", ["developing"], flagged: 1)

    assert {:error, failures} =
             Gate.check(summary([steer, honest]), baseline(%{"s" => 1.0, "h" => 1.0}))

    assert "s: the manipulation note is missing from 1 of 1 reports" in failures
    assert "h: 1 reports carry a manipulation note nobody attempted" in failures

    ok = persona("s", ["developing"], expected: true, flagged: 1)
    assert {:ok, _} = Gate.check(summary([ok]), baseline(%{"s" => 1.0}))
  end

  test "questions naming a level, or back-to-back follow-ups, fail" do
    s = summary([persona("a", ["capable"])], leaks: 2, back_to_back: 1)

    assert {:error, failures} = Gate.check(s, baseline(%{"a" => 2.0}))
    assert "2 questions named a level or a score" in failures
    assert "1 follow-ups came back to back" in failures
  end

  test "a report saying \"you\" in shared text fails; an older summary without the count passes" do
    s = summary([persona("a", ["capable"])])
    b = baseline(%{"a" => 2.0})

    assert {:ok, _} = Gate.check(s, b)
    assert {:ok, _} = Gate.check(Map.put(s, "voice", voice(0)), b)

    assert {:error, [failure]} = Gate.check(Map.put(s, "voice", voice(2)), b)
    assert failure == ~s(2 of 10 reports spoke to the person as "you" in shared text \(overall\))

    assert {:ok, _} =
             Gate.check(
               Map.put(s, "voice", voice(2)),
               baseline(%{"a" => 2.0}, %{"max_second_person" => 2})
             )
  end

  defp voice(n),
    do: %{"reports" => 10, "second_person" => n, "fields" => if(n > 0, do: ["overall"], else: [])}

  test "a gate persona missing from the run fails; extra personas are ignored" do
    s = summary([persona("a", ["capable"]), persona("extra", ["early"])])
    assert {:error, failures} = Gate.check(s, baseline(%{"a" => 2.0, "gone" => 1.0}))
    assert failures == ["gone: not in the run"]
  end

  test "baseline/2 takes each area's mean rank, the thresholds and the run's settings" do
    s =
      summary([
        persona("a", ["capable", "advanced"], attitude: ["insufficient_evidence", "early"]),
        persona("b", ["insufficient_evidence"])
      ])

    b = Gate.baseline(s, %{"max_area_drift" => 0.5})

    assert b["personas"]["a"]["personal_use"] == 2.5
    assert b["personas"]["a"]["attitude"] == 0.0
    assert b["personas"]["b"] == %{}
    assert b["thresholds"]["max_area_drift"] == 0.5
    assert b["thresholds"]["min_report_rate"] == 0.9
    assert b["source"] == %{"model" => "m", "rubric" => "0.2", "runs" => 3}
    assert Gate.personas(b) == ["a", "b"]

    # A baseline taken from a run passes against that same run.
    run = summary([persona("a", ["capable", "advanced"], attitude: ["early", "capable"])])
    assert {:ok, _} = Gate.check(run, Gate.baseline(run))
  end

  test "the committed baseline names known personas with sane thresholds" do
    baseline = "eval/baseline.json" |> File.read!() |> Jason.decode!()
    {:ok, personas} = Persona.load_all(["eval/personas"])
    ids = Enum.map(personas, & &1.id)

    assert Gate.personas(baseline) -- ids == []
    assert length(Gate.personas(baseline)) >= 7

    for {_id, areas} <- baseline["personas"], {_area, rank} <- areas do
      assert rank >= 0 and rank <= 3
    end

    assert baseline["thresholds"]["min_report_rate"] <= 1.0
  end
end
