defmodule AiInPractice.Reports.PayloadTest do
  use AiInPractice.DataCase, async: true

  import AiInPractice.ReportFixtures
  import ExUnit.CaptureLog

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Reports.{Canonical, Content, Payload, PDF, Signing}
  alias AiInPractice.{Rubric, Version}

  test "holds the header facts, versions and statement" do
    payload = Payload.assessor(report_fixture(), meta_fixture())

    assert payload["format"] == "ai-in-practice/assessor-report/1"
    assert payload["role_group"] == "finance"
    assert payload["role_group_name"] == "Finance"
    assert payload["date"] == "2026-10-13"
    assert payload["answers"] == "typed"
    assert payload["link"] == "from a recruiter"
    assert payload["statement"] == Content.statement()

    assert payload["versions"] == %{
             "code" => Version.code_version(),
             "rubric" => Version.rubric_version(),
             "model" => Version.model()
           }

    other =
      Payload.assessor(report_fixture(), meta_fixture(%{mode: :voice, link_kind: :individual}))

    assert other["answers"] == "spoken"
    assert other["link"] == "individual"
  end

  test "a sample says so in the signed content; a real report has no sample key" do
    report = report_fixture()
    real = Payload.assessor(report, meta_fixture())
    sample = Payload.assessor(report, meta_fixture(%{sample: true}))

    refute Map.has_key?(real, "sample")
    refute Map.has_key?(Payload.assessor(report, meta_fixture(%{sample: false})), "sample")
    assert sample["sample"] == Content.sample()
    assert Map.delete(sample, "sample") == real

    # Signed with the marker, so removing it breaks the signature.
    {:ok, keyring} = Signing.parse(private_key: Signing.generate().private_key)
    envelope = Signing.envelope(sample, keyring)
    assert {:ok, %{"sample" => _}} = Signing.verify(envelope, keyring)

    stripped = envelope |> Jason.decode!() |> update_in(["payload"], &Map.delete(&1, "sample"))
    assert {:error, _} = Signing.verify(Jason.encode!(stripped), keyring)
  end

  test "holds every assessor section, in the report's words" do
    report = report_fixture()
    payload = Payload.assessor(report, meta_fixture())

    assert payload["summary"] == report.summary
    assert payload["overall"] == report.overall
    assert payload["explore_next"] == report.assessor_next_steps

    assert payload["follow_up_questions"] ==
             for(
               q <- report.follow_up_questions,
               do: %{"question" => q.question, "listen_for" => q.listen_for}
             )

    assert Enum.map(payload["areas"], & &1["area"]) == Enum.map(Rubric.areas(), &Atom.to_string/1)

    for {area, sent} <- Enum.zip(report.areas, payload["areas"]) do
      assert sent["name"] == Rubric.area_name(area.area)
      assert sent["description"] == area.description
      assert sent["quotes"] == area.quotes
      assert sent["confidence_in_words"] == area.confidence_in_words
      assert sent["strong_answer"] == area.strong_answer
      assert sent["shortfall"] == area.shortfall
    end

    assert payload["manipulation_note"] == nil
  end

  test "carries the manipulation note when the transcript tried to direct the assessment" do
    report = report_fixture(["One."], %{"manipulation_attempted" => true})

    assert Payload.assessor(report, meta_fixture())["manipulation_note"] ==
             Report.manipulation_note()
  end

  test "is plain JSON, so it encodes canonically" do
    payload = Payload.assessor(report_fixture(), meta_fixture())
    bytes = Canonical.encode!(payload)
    assert Jason.decode!(bytes) == payload
  end

  @tag :privacy
  test "never carries internal levels, confidence, validation counts or the link id" do
    report = report_fixture()
    bytes = Canonical.encode!(Payload.assessor(report, meta_fixture(%{link_id: 4321})))
    keys = ~r/"(level|confidence|dropped|link_id|manipulation_attempted)":/

    refute bytes =~ keys
    refute bytes =~ "4321"

    for area <- report.areas do
      refute bytes =~ ~s("#{area.level}")
      refute bytes =~ ~s("#{area.confidence}")
    end
  end

  @tag :privacy
  test "rendering and signing a report logs nothing" do
    report = report_fixture(["A distinctive answer about the Hartwell forecast."])

    log =
      capture_log([level: :debug], fn ->
        PDF.render(:assessor, report, meta_fixture())
        PDF.render(:candidate, report, meta_fixture())
        Signing.verify(Signing.envelope(Payload.assessor(report, meta_fixture())))
      end)

    refute log =~ "Hartwell"
    refute log =~ report.summary
  end
end
