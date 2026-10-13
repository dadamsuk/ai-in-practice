defmodule AiInPractice.LLMTest do
  # Not async: changes the :llm application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.LLM
  alias AiInPractice.LLMScript

  setup do
    previous = Application.fetch_env!(:ai_in_practice, :llm)
    on_exit(fn -> Application.put_env(:ai_in_practice, :llm, previous) end)
  end

  test "client/0 reads a {module, opts} pair or a bare module" do
    Application.put_env(:ai_in_practice, :llm, {LLM.Fake, questions: 2})
    assert LLM.client() == {LLM.Fake, questions: 2}

    Application.put_env(:ai_in_practice, :llm, LLM.Fake)
    assert LLM.client() == {LLM.Fake, []}
  end

  test "complete/1 uses the configured client" do
    Application.put_env(:ai_in_practice, :llm, LLM.Fake)
    request = %{purpose: :turn, messages: [%{role: "user", content: "x"}]}
    assert {:ok, %{data: %{"question" => _}}} = LLM.complete(request)
  end

  test "retries transient failures only, up to the backoff list" do
    request = %{purpose: :turn, messages: []}

    {client, agent} =
      LLMScript.client([{:error, :transient}, {:error, :transient}, {:ok, %{"a" => 1}}])

    capture_log(fn -> assert {:ok, %{data: %{"a" => 1}}} = LLM.complete(request, client) end)
    assert LLMScript.calls(agent) == 3

    {client, agent} = LLMScript.client(List.duplicate({:error, :transient}, 5))
    capture_log(fn -> assert {:error, :transient} = LLM.complete(request, client) end)
    assert LLMScript.calls(agent) == 3

    for class <- [:spend_refused, :rate_limited, :fatal] do
      {client, agent} = LLMScript.client([{:error, class}, {:ok, %{}}])
      capture_log(fn -> assert {:error, ^class} = LLM.complete(request, client) end)
      assert LLMScript.calls(agent) == 1
    end
  end

  test "response_format/1 is a strict json_schema" do
    assert LLM.response_format({"n", %{type: "object"}}) == %{
             type: "json_schema",
             json_schema: %{name: "n", strict: true, schema: %{type: "object"}}
           }
  end
end
