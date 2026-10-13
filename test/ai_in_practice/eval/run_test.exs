defmodule AiInPractice.Eval.RunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.{FakeRespondent, Persona, Run}
  alias AiInPractice.LLM.Fake
  alias AiInPractice.Rubric

  defp persona(group \\ :operations) do
    %Persona{
      id: "ops",
      role_group: group,
      seniority: "COO",
      sector: "Logistics",
      company_size: "300 people",
      language: "Native",
      style: "Brief.",
      background: "Runs three warehouses. Uses AI for rota planning.",
      levels: Map.new(Rubric.areas(), &{&1, :developing})
    }
  end

  defp run(engine, respondent \\ {FakeRespondent, []}, opts \\ []) do
    {result, _log} =
      with_log(fn -> Run.run(persona(), 1, engine, respondent, [reading: []] ++ opts) end)

    result
  end

  test "a whole conversation: every question answered in character, then the report" do
    r = run({Fake, questions: 4})

    assert %{persona: "ops", run: 1, outcome: :report, failure: nil, closed: :covered} = r
    assert length(r.transcript) == 4
    assert length(r.question_ms) == 4
    assert is_integer(r.report_ms)
    assert r.elapsed_ms >= r.report_ms

    for {entry, n} <- Enum.with_index(r.transcript, 1) do
      assert entry.question != ""
      assert entry.kind == :main
      assert entry.answer == "Runs three warehouses. (answer #{n})"
    end

    assert Enum.map(r.report.areas, & &1.area) == Rubric.areas()
    assert Enum.all?(r.report.areas, &(&1.level == :developing))
    assert r.report.manipulation_note == false
  end

  test "an engine failure mid-conversation is a failed run, with what was said so far" do
    r = run({Fake, fail_turn: {2, :fatal}})

    assert %{outcome: :failed, failure: :fatal, report: nil, report_ms: nil} = r
    assert length(r.transcript) == 2
  end

  test "a report that cannot be written is a failed run with the close reason" do
    r = run({Fake, questions: 2, fail_report: :report_invalid})
    assert %{outcome: :failed, failure: :report_invalid, closed: :covered} = r
  end

  test "a respondent failure ends the run and names the respondent" do
    r = run({Fake, questions: 5}, {FakeRespondent, fail_after: {1, :spend_refused}})

    assert %{outcome: :failed, failure: :respondent_spend_refused} = r
    assert [%{answer: answer}, %{answer: nil}] = r.transcript
    assert answer =~ "(answer 1)"
  end

  test "an engine that goes quiet times out" do
    slow = {Fake, responder: fn _ -> Process.sleep(1_000) && {:error, :transient} end}
    r = run(slow, {FakeRespondent, []}, event_timeout_ms: 50)
    assert %{outcome: :failed, failure: :timeout, transcript: []} = r
  end

  test "a session that will not start is a failed run" do
    result = Run.run(persona(:astronaut), 2, {Fake, []}, {FakeRespondent, []}, reading: [])
    assert %{run: 2, outcome: :failed, failure: :unknown_role_group} = result
  end

  test "the manipulation note is carried into the result when the report flags it" do
    responder = fn
      %{purpose: :report} ->
        data = %{Fake.report([]) | "manipulation_attempted" => true}
        {:ok, %{content: Jason.encode!(data), data: data, usage: %{total_tokens: 1}}}

      request ->
        Fake.request(request, questions: 1)
    end

    r = run({Fake, responder: responder})
    assert r.report.manipulation_attempted
    assert r.report.manipulation_note =~ "attempts to direct the assessment"
  end
end
