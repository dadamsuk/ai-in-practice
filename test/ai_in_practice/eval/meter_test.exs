defmodule AiInPractice.Eval.MeterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.Meter
  alias AiInPractice.{LLM, LLMScript}

  defp request(purpose \\ :turn), do: %{purpose: purpose, messages: [], max_tokens: 10}

  defp ok(usage), do: fn _ -> {:ok, %{content: "x", data: nil, usage: usage}} end

  defp client(responder), do: {AiInPractice.LLM.Fake, responder: responder}

  test "counts calls, tokens and the reported cost, by purpose and tag" do
    {:ok, meter} = Meter.start_link()
    metered = Meter.client(meter, client(ok(%{total_tokens: 120, cost: 0.01})), tag: {"p", 1})

    assert {:ok, _} = LLM.complete(request(), metered)
    assert {:ok, _} = LLM.complete(request(:report), metered)

    assert %{calls: 2, tripped: false, cost: cost} = Meter.totals(meter)
    assert_in_delta cost, 0.02, 1.0e-9

    assert [
             %{purpose: :turn, tag: {"p", 1}, tokens: 120, outcome: :ok},
             %{purpose: :report, tokens: 120}
           ] = Meter.records(meter)
  end

  test "without a reported cost, spend is estimated from tokens at the fallback price" do
    {:ok, meter} = Meter.start_link(fallback_usd_per_mtok: 2.0)
    metered = Meter.client(meter, client(ok(%{total_tokens: 500_000})))

    assert {:ok, _} = LLM.complete(request(), metered)
    assert Meter.totals(meter).cost == 1.0
  end

  test "a failed call is counted with its class and no cost" do
    {:ok, meter} = Meter.start_link()
    metered = Meter.client(meter, client(fn _ -> {:error, :fatal} end))

    capture_log(fn -> assert {:error, :fatal} = LLM.complete(request(), metered) end)
    assert [%{outcome: :fatal, cost: +0.0, tokens: 0}] = Meter.records(meter)
  end

  test "the call cap refuses further requests as spend_refused, without sending them" do
    {:ok, meter} = Meter.start_link(max_calls: 2)
    {inner, script} = LLMScript.client([])
    metered = Meter.client(meter, inner)

    capture_log(fn ->
      assert {:ok, _} = LLM.complete(request(), metered)
      assert {:ok, _} = LLM.complete(request(), metered)
      assert Meter.exhausted?(meter)
      assert {:error, :spend_refused} = LLM.complete(request(), metered)
      assert {:error, :spend_refused} = LLM.complete(request(), metered)
    end)

    assert LLMScript.calls(script) == 2
    assert %{calls: 2, tripped: true} = Meter.totals(meter)
    assert Meter.exhausted?(meter)
  end

  test "the spend cap stops sending once reached" do
    {:ok, meter} = Meter.start_link(max_cost: 0.05)
    metered = Meter.client(meter, client(ok(%{total_tokens: 1, cost: 0.03})))

    capture_log(fn ->
      assert {:ok, _} = LLM.complete(request(), metered)
      refute Meter.exhausted?(meter)
      assert {:ok, _} = LLM.complete(request(), metered)
      assert Meter.exhausted?(meter)
      assert {:error, :spend_refused} = LLM.complete(request(), metered)
    end)

    assert Meter.totals(meter).calls == 2
  end

  test "concurrent callers cannot overshoot the call cap" do
    {:ok, meter} = Meter.start_link(max_calls: 5)
    metered = Meter.client(meter, client(ok(%{total_tokens: 1})))

    {results, _log} =
      with_log(fn ->
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> LLM.complete(request(), metered) end) end)
        |> Task.await_many()
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 5
    assert Enum.count(results, &(&1 == {:error, :spend_refused})) == 15
  end

  test "report calls can go to a different client" do
    {:ok, meter} = Meter.start_link()
    {main, main_script} = LLMScript.client([])
    {report, report_script} = LLMScript.client([])
    metered = Meter.client(meter, main, report_client: report)

    assert {:ok, _} =
             LLM.complete(
               %{request() | purpose: :turn, messages: [%{role: "user", content: ""}]},
               metered
             )

    assert {:ok, _} =
             LLM.complete(%{request(:report) | messages: [%{role: "user", content: ""}]}, metered)

    assert LLMScript.calls(main_script) == 1
    assert LLMScript.calls(report_script) == 1
  end
end
