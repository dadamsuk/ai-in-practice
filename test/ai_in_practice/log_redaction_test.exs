defmodule AiInPractice.LogRedactionTest do
  # Not async: crashes processes and captures logs from all of them.
  use ExUnit.Case, async: false

  alias AiInPractice.GlobalLog
  alias AiInPractice.LogRedaction

  @moduletag :privacy

  defmodule Server do
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call(:ok, _from, state), do: {:reply, :ok, state}
  end

  test "the filter runs before Elixir's translator" do
    LogRedaction.install()
    LogRedaction.install()
    filters = :logger.get_primary_config().filters |> Keyword.keys()
    assert Enum.count(filters, &(&1 == LogRedaction)) == 1

    assert Enum.find_index(filters, &(&1 == LogRedaction)) <
             Enum.find_index(filters, &(&1 == :logger_translator))
  end

  test "any GenServer's crash report loses its state, message strings and call arguments" do
    {:ok, pid} = GenServer.start(Server, %{answer: "GS-MARKER-STATE"})
    ref = Process.monitor(pid)

    log =
      GlobalLog.capture(:warning, fn ->
        catch_exit(GenServer.call(pid, {:answer, "GS-MARKER-MESSAGE"}))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end)

    assert log =~ "terminating"
    assert log =~ "handle_call/3"
    refute log =~ "GS-MARKER"
  end

  test "a crashing task's report loses its arguments" do
    log =
      GlobalLog.capture(:warning, fn ->
        {:ok, pid} = Task.start(fn -> String.to_integer("TASK-MARKER not a number") end)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end)

    assert log =~ "ArgumentError"
    refute log =~ "TASK-MARKER"
  end

  test "strip_stacks/1 turns arguments into arities, through improper lists and maps" do
    stack = [{M, :f, ["secret", 1], [line: 1]}, {M, :g, 2, []}]

    assert LogRedaction.strip_stacks({:boom, stack}) ==
             {:boom, [{M, :f, 2, [line: 1]}, {M, :g, 2, []}]}

    assert LogRedaction.strip_stacks([:alias | :ref]) == [:alias | :ref]
    assert LogRedaction.strip_stacks(%{s: stack}) == %{s: [{M, :f, 2, [line: 1]}, {M, :g, 2, []}]}
    error = %RuntimeError{message: "kept"}
    assert LogRedaction.strip_stacks(error) == error
  end

  test "scrub/1 replaces every string and reduces structs to their module" do
    assert LogRedaction.scrub({:answer, ["a", %{"k" => "v"}], 3}) ==
             {:answer, [:redacted, %{redacted: :redacted}], 3}

    assert LogRedaction.scrub([:alias | "x"]) == [:alias | :redacted]
    assert LogRedaction.scrub(%URI{host: "x"}) == URI
  end

  test "other OTP reports have their stacks stripped; non-OTP events pass untouched" do
    event = %{
      msg: {:report, %{label: :other, stack: [{M, :f, ["x"], []}]}},
      meta: %{domain: [:otp]}
    }

    assert %{msg: {:report, %{stack: [{M, :f, 1, []}]}}} = LogRedaction.filter(event, [])
    assert LogRedaction.filter(%{msg: {:string, "hi"}, meta: %{}}, []) == :ignore
  end

  test "a report that cannot be redacted is withheld" do
    event = %{
      msg: {:report, %{label: {:proc_lib, :crash}, report: [[messages: "x"] | :not_a_list]}},
      meta: %{domain: [:otp, :sasl]}
    }

    # A well-formed crash report is rewritten...
    assert %{msg: {:report, %{report: [[messages: :redacted] | :not_a_list]}}} =
             LogRedaction.filter(event, [])

    # A termination report has its state and message redacted...
    terminate = %{
      event
      | msg:
          {:report, %{label: {:gen_server, :terminate}, state: 1, reason: 1, last_message: "m"}}
    }

    assert %{msg: {:report, %{state: :redacted, last_message: :redacted}}} =
             LogRedaction.filter(terminate, [])

    # ...and a report whose redaction raises (an improper list where the
    # report items should be) is withheld.
    bad = %{event | msg: {:report, %{label: {:proc_lib, :crash}, report: [[:a | :b]]}}}

    assert %{msg: {:string, "an OTP report was withheld" <> _}} = LogRedaction.filter(bad, [])
  end
end
