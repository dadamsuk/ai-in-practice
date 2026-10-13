defmodule AiInPractice.LLM.FakeTest do
  use ExUnit.Case, async: true

  alias AiInPractice.LLM.Fake

  defp turn(asked) do
    questions = Enum.map_join(1..asked//1, "\n", fn n -> ~s(<question n="#{n}">Q</question>) end)
    %{purpose: :turn, messages: [%{role: "user", content: questions}]}
  end

  @report %{purpose: :report, messages: [%{role: "user", content: "<answer>\nOne.\n</answer>"}]}

  test "by default asks five questions, then closes" do
    assert {:ok, %{data: %{"question" => q, "close" => false}}} = Fake.request(turn(0), [])
    assert q =~ "last piece of real work"
    assert {:ok, %{data: %{"close" => true}}} = Fake.request(turn(5), [])
  end

  test ":fail_turn fails every turn from the nth question" do
    opts = [fail_turn: {2, :fatal}]
    assert {:ok, _} = Fake.request(turn(0), opts)
    assert {:ok, _} = Fake.request(turn(1), opts)
    assert {:error, :fatal} = Fake.request(turn(2), opts)
    assert {:error, :spend_refused} = Fake.request(turn(0), fail_turn: {0, :spend_refused})
  end

  test ":fail_report fails the report call, or makes it invalid" do
    assert {:ok, %{data: %{"summary" => _, "areas" => _}}} = Fake.request(@report, [])
    assert {:error, :transient} = Fake.request(@report, fail_report: :transient)
    assert {:ok, %{data: data}} = Fake.request(@report, fail_report: :report_invalid)
    refute Map.has_key?(data, "areas")
  end

  test ":flaky fails the nth turn and the report for their first tries, per answer" do
    answered = fn asked, answer ->
      questions =
        Enum.map_join(1..asked//1, "\n", fn n -> ~s(<question n="#{n}">Q</question>) end)

      text = questions <> "\n<answer>\n#{answer}\n</answer>"
      %{purpose: :turn, messages: [%{role: "user", content: text}]}
    end

    marker = "flaky-#{System.unique_integer([:positive])}"
    opts = [flaky: {2, :rate_limited, 2}]

    # Other turns are never affected.
    assert {:ok, _} = Fake.request(turn(1), opts)
    assert {:ok, _} = Fake.request(answered.(3, marker), opts)

    # The nth: two failures, then through.
    assert {:error, :rate_limited} = Fake.request(answered.(2, marker), opts)
    assert {:error, :rate_limited} = Fake.request(answered.(2, marker), opts)
    assert {:ok, %{data: %{"question" => _}}} = Fake.request(answered.(2, marker), opts)

    # A different answer is a different try.
    assert {:error, :rate_limited} = Fake.request(answered.(2, marker <> "-b"), opts)

    report = %{
      purpose: :report,
      messages: [%{role: "user", content: "<answer>\n#{marker}\n</answer>"}]
    }

    assert {:error, :rate_limited} = Fake.request(report, opts)
    assert {:error, :rate_limited} = Fake.request(report, opts)
    assert {:ok, %{data: %{"areas" => _}}} = Fake.request(report, opts)
  end

  test ":report_delay_ms holds the report back, and not a turn" do
    {micros, result} = :timer.tc(fn -> Fake.request(@report, report_delay_ms: 50) end)
    assert {:ok, %{data: %{"areas" => _}}} = result
    assert micros >= 50_000

    {micros, _} = :timer.tc(fn -> Fake.request(turn(0), report_delay_ms: 5_000) end)
    assert micros < 1_000_000
  end

  test "the FAKE_LLM modes" do
    modes = Fake.modes()
    assert modes["1"] == []
    assert modes["spend_refused"] == [fail_turn: {0, :spend_refused}]
    assert modes["fail_mid"] == [fail_turn: {2, :fatal}]
    assert modes["report_invalid"] == [fail_report: :report_invalid]
    assert modes["short"] == []
    assert modes["flaky"] == [flaky: {2, :transient, 3}]
    assert modes["slow"] == [report_delay_ms: 20_000]
    refute Map.has_key?(modes, "0")
  end
end
