defmodule AiInPractice.Assessment.SessionPrivacyTest do
  # Not async: captures logs from every process.
  use ExUnit.Case, async: false

  import AiInPractice.SessionHelpers

  alias AiInPractice.Assessment
  alias AiInPractice.Assessment.Session
  alias AiInPractice.GlobalLog
  alias AiInPractice.LLMScript

  @moduletag :privacy

  defp answered_session(answer, script \\ [LLMScript.turn("Q1"), LLMScript.turn("Q2")]) do
    {id, agent} = start!(script)
    assert_event(id, {:question, _})
    :ok = Assessment.answer(id, answer)
    {id, agent}
  end

  test ":sys.get_status shows no transcript or report" do
    {id, _} = answered_session("STATUS-MARKER we cut invoice errors by a third")
    assert_event(id, {:question, %{text: "Q2"}})

    status =
      id
      |> Session.whereis()
      |> :sys.get_status()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute status =~ "STATUS-MARKER"
    assert status =~ "transcript: :redacted"
  end

  test "the raw state inspects without words" do
    {id, _} = answered_session("STATE-MARKER we cut invoice errors")
    assert_event(id, {:question, %{text: "Q2"}})

    state = id |> Session.whereis() |> :sys.get_state() |> inspect(limit: :infinity)
    refute state =~ "STATE-MARKER"
    assert state =~ "#Transcript<2 turns, redacted>"
  end

  test "a session crash report shows no transcript, report, message or call arguments" do
    {id, _} =
      answered_session("CRASH-MARKER-ANSWER invoice errors", [
        LLMScript.turn("Q1"),
        LLMScript.turn("", [], close: true)
      ])

    assert_event(id, {:report, _})
    pid = Session.whereis(id)
    ref = Process.monitor(pid)

    log =
      GlobalLog.capture(:warning, fn ->
        # No clause handles this call, so the session crashes with the
        # request and its state in the failing frame's arguments.
        catch_exit(GenServer.call(pid, {:unexpected, "CRASH-MARKER-MESSAGE"}))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      end)

    assert log =~ "terminating"
    assert log =~ "FunctionClauseError" or log =~ "function_clause"
    assert log =~ "handle_call/3"
    refute log =~ "CRASH-MARKER"
    refute log =~ "They described"
  end

  test "a model call that raises is fatal and logs only the exception type" do
    log =
      GlobalLog.capture(fn ->
        {id, _} = start!([fn _ -> raise "RAISE-MARKER in the exception" end])
        assert_event(id, {:failed, :fatal})
      end)

    assert log =~ "assessment model call raised RuntimeError"
    refute log =~ "RAISE-MARKER"
  end

  test "a model call that exits is fatal and logs only the kind" do
    log =
      GlobalLog.capture(fn ->
        {id, _} = start!([fn _ -> exit({:shutdown, "EXIT-MARKER"}) end])
        assert_event(id, {:failed, :fatal})
      end)

    assert log =~ "assessment model call failed (exit)"
    refute log =~ "EXIT-MARKER"
  end

  test "format_status/1 keeps an exception's type and drops its message and arguments" do
    stack = [{Session, :handle_info, [{:x, "FS-MARKER"}, :state], [line: 1]}]

    assert %{reason: {RuntimeError, [{Session, :handle_info, 2, [line: 1]}]}} =
             Session.format_status(%{reason: {%RuntimeError{message: "FS-MARKER"}, stack}})

    assert %{reason: {{:bad, :redacted}, [{Session, :handle_info, 2, [line: 1]}]}} =
             Session.format_status(%{reason: {{:bad, "FS-MARKER"}, stack}})

    assert %{
             reason: {:shutdown, :redacted},
             state: :redacted,
             message: {:answer, :redacted},
             log: []
           } =
             Session.format_status(%{
               reason: {:shutdown, "FS-MARKER"},
               state: "FS-MARKER",
               message: {:answer, "FS-MARKER"},
               log: [{:in, "FS-MARKER"}]
             })
  end

  test "a whole conversation logs nothing that was said" do
    log =
      GlobalLog.capture(fn ->
        {id, _} =
          answered_session("FLOW-MARKER-ANSWER we cut invoice errors", [
            LLMScript.turn("FLOW-MARKER-QUESTION"),
            {:error, :transient},
            LLMScript.turn("", [], close: true)
          ])

        assert_event(id, {:report, _})
      end)

    assert log =~ "assessment closed: covered, 1 answers"
    assert log =~ "transient failure, retrying"
    refute log =~ "FLOW-MARKER"
    refute log =~ "invoice"
  end
end
