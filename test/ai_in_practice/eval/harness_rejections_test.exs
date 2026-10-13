defmodule AiInPractice.Eval.HarnessRejectionsTest do
  # Not async: the harness counts report rejections through a global
  # telemetry handler, so another harness run would add to the count.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.{FakeRespondent, Harness, Persona, Summary}
  alias AiInPractice.LLM.Fake
  alias AiInPractice.Rubric

  test "report rejections are counted by rule and path, and the handler is removed" do
    persona = %Persona{
      id: "p",
      role_group: :ceo_gm,
      seniority: "CEO",
      sector: "Retail",
      company_size: "80 people",
      language: "Native",
      style: "Brief.",
      background: "Runs a shop.",
      levels: Map.new(Rubric.areas(), &{&1, :early})
    }

    {s, _log} =
      with_log(fn ->
        Harness.run([persona],
          engine: {Fake, questions: 2, fail_report: :report_invalid},
          respondent: {FakeRespondent, []},
          reading: [],
          runs: 1
        )
      end)

    assert s.totals.reports == 0
    assert hd(s.personas).failures == [:report_invalid]
    assert s.rejections["missing at overall"] == 2
    assert s.rejections["missing at areas"] == 2
    assert Summary.markdown(s, %{}) =~ "missing at overall (2)"

    assert :telemetry.list_handlers([:ai_in_practice, :report, :rejected]) == []
  end
end
