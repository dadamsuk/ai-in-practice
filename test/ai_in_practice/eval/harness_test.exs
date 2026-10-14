defmodule AiInPractice.Eval.HarnessTest do
  # Not async: the harness counts report rejections through a global
  # telemetry handler, which would also count those of report tests
  # running alongside.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.{FakeRespondent, Harness, Persona, Summary}
  alias AiInPractice.LLM.Fake
  alias AiInPractice.Rubric

  defp persona(id, opts \\ []) do
    %Persona{
      id: id,
      role_group: :people,
      seniority: "HR director",
      sector: "Retail",
      company_size: "50 people",
      language: "Native",
      style: "Brief.",
      background: "Leads a small HR team.",
      levels: Map.new(Rubric.areas(), &{&1, :developing}),
      pair: opts[:pair]
    }
  end

  defp harness(personas, opts) do
    {summary, _log} =
      with_log(fn ->
        Harness.run(
          personas,
          [engine: {Fake, questions: 3}, respondent: {FakeRespondent, []}, reading: []] ++ opts
        )
      end)

    summary
  end

  test "runs every persona the given number of times and summarises them" do
    parent = self()

    s =
      harness([persona("a"), persona("b")],
        runs: 2,
        on_result: &send(parent, {:result, &1.persona, &1.run})
      )

    for id <- ~w(a b), n <- 1..2, do: assert_received({:result, ^id, ^n})

    assert %{runs: 4, reports: 4, first_pass: 4, tripped: false} = s.totals
    # Per run: 4 turn calls (3 questions and a close), 3 answers, 1 report.
    assert s.totals.calls == 4 * 8
    assert %{turn: %{count: 16}, respondent: %{count: 12}, report: %{count: 4}} = s.calls
    assert s.calls.turn.errors == %{}
    assert Enum.map(s.personas, & &1.persona) == ~w(a b)
    assert Enum.all?(s.personas, &(&1.reports == 2))
    assert is_float(s.cost_per_report) and s.cost_per_report > 0
    assert %{p50: _, p95: _, max: _} = s.latency.question_ms
    assert %{p50: _, p95: _, max: _} = s.latency.report_ms
    assert s.pairs == []

    markdown = Summary.markdown(s, %{model: "fake", runs: 2})
    assert markdown =~ "- model: fake"
    assert markdown =~ "Runs: 4; reports written: 4; valid on the first attempt: 4"
    assert markdown =~ "### a (people)"
    assert markdown =~ "| Personal use | developing | developing, developing | 0 | 0.00 | 1.00 |"
    assert markdown =~ "| report | 4 | none |"
    assert markdown =~ "Report rejections (each regenerated once): none"
    assert markdown =~ "Questions: 3.00 per run, 0 follow-ups (0 back to back)"
    assert markdown =~ "Voice: no report of 4 broke its perspective"
    assert s.voice == %{reports: 4, second_person: 0, third_person: 0, fields: []}

    assert %{runs: 4, questions: 12, follow_ups: 0, consecutive_follow_ups: 0} = s.questions
    assert %{runs: 2, questions: 6} = hd(s.personas).questions
  end

  test "the budget cap stops sending; runs after it are skipped" do
    s = harness([persona("a"), persona("b")], runs: 2, max_calls: 10, concurrency: 1)

    assert s.totals.tripped
    assert s.totals.calls == 10
    assert s.totals.reports == 1

    [a, b] = s.personas
    assert a.reports == 1
    assert a.failures == [:spend_refused]
    assert b.failures == [:budget, :budget]

    assert Summary.markdown(s, %{}) =~ "a cap was reached; later runs were skipped"
  end

  test "a mutual pair is compared once; a one-sided pair is compared too" do
    s =
      harness(
        [persona("a", pair: "b"), persona("b", pair: "a"), persona("c", pair: "a")],
        runs: 1
      )

    assert Enum.map(s.pairs, & &1.personas) == [{"a", "b"}, {"c", "a"}]
    assert Enum.all?(hd(s.pairs).areas, &(&1.shift == 0.0))
    assert Summary.markdown(s, %{}) =~ "### a vs b"
  end

  test "a pair whose partner is not in this run is left out" do
    s = harness([persona("a", pair: "elsewhere")], runs: 1)
    assert s.pairs == []
  end

  test "a report sent to a separate client is counted under report" do
    parent = self()

    report_client =
      {Fake,
       responder: fn request ->
         send(parent, :report_client_used)
         Fake.request(request, [])
       end}

    s = harness([persona("a")], runs: 1, report_client: report_client)
    assert_received :report_client_used
    assert s.calls.report.count == 1
  end

  describe "stats/1" do
    test "nearest-rank percentiles" do
      assert Harness.stats([]) == nil
      assert Harness.stats([7]) == %{p50: 7, p95: 7, max: 7}
      assert Harness.stats(Enum.to_list(100..1//-1)) == %{p50: 50, p95: 95, max: 100}
    end
  end
end
