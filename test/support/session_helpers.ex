defmodule AiInPractice.SessionHelpers do
  @moduledoc "Starting scripted assessment sessions and waiting for their events, in tests."

  import ExUnit.Assertions

  alias AiInPractice.Assessment
  alias AiInPractice.Assessment.Session
  alias AiInPractice.LLMScript

  def start!(script, opts \\ []) do
    {client, agent} = LLMScript.client(script, Keyword.get(opts, :fake, []))
    limits = Keyword.get(opts, :limits, %{})

    {:ok, id} =
      Assessment.start(Keyword.get(opts, :role, :finance),
        llm: client,
        reading: Keyword.get(opts, :reading, []),
        limits: limits
      )

    {id, agent}
  end

  defmacro assert_event(id, pattern, timeout \\ 1000) do
    quote do
      assert_receive {AiInPractice.Assessment, ^unquote(id), unquote(pattern)}, unquote(timeout)
    end
  end

  defmacro refute_event(id, pattern, timeout \\ 100) do
    quote do
      refute_receive {AiInPractice.Assessment, ^unquote(id), unquote(pattern)}, unquote(timeout)
    end
  end

  def gone?(id) do
    pid = Session.whereis(id)

    if pid do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    # The registry unregisters asynchronously after the process exits.
    Enum.reduce_while(1..50, false, fn _, _ ->
      if Session.whereis(id) == nil do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
