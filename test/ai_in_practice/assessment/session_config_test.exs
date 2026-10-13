defmodule AiInPractice.Assessment.SessionConfigTest do
  # Not async: changes the :assessment_limits application environment.
  use ExUnit.Case, async: false

  import AiInPractice.SessionHelpers

  alias AiInPractice.Assessment
  alias AiInPractice.LLMScript

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:ai_in_practice, :assessment_limits)
    on_exit(fn -> Application.put_env(:ai_in_practice, :assessment_limits, previous) end)
  end

  test "limits in config apply, and a session's own limits win over them" do
    Application.put_env(:ai_in_practice, :assessment_limits, %{hard_stop_ms: 50, reattach_ms: 0})

    {id, _} = start!([LLMScript.turn("Q1"), LLMScript.turn("Q2")])
    assert_event(id, {:question, _})
    :ok = Assessment.answer(id, "One.")
    assert_event(id, {:closed, :time_limit}, 1000)

    {id, _} = start!([LLMScript.turn("Q1")], limits: %{hard_stop_ms: 10_000})
    assert_event(id, {:question, _})
    refute_event(id, {:closed, _}, 150)
  end
end
