defmodule AiInPractice.Assessment.SessionAttachTest do
  # Reattaching after a lost connection, downloads and the report's expiry.
  use ExUnit.Case, async: true

  import AiInPractice.SessionHelpers

  alias AiInPractice.Assessment
  alias AiInPractice.Assessment.{Report, Session}
  alias AiInPractice.LLMScript

  @meta %{link_id: 42, link_kind: :candidate}

  # A session owned by a separate process, so the test can kill the owner
  # and attach in its place.
  defp owned_session(script, limits) do
    test = self()

    owner =
      spawn(fn ->
        {client, _} = LLMScript.client(script)

        {:ok, id} =
          Assessment.start(:people, llm: client, reading: [], limits: limits, meta: @meta)

        send(test, {:id, id})

        receive do
          {Assessment, ^id, {:question, q}} -> send(test, {:owner_saw, q})
        end

        Process.sleep(:infinity)
      end)

    assert_receive {:id, id}
    assert_receive {:owner_saw, _}, 1000
    {id, owner}
  end

  defp same_link, do: &(&1[:link_id] == 42)

  test "a new owner can attach after the old one is gone, and gets the question on screen" do
    {id, owner} =
      owned_session([LLMScript.turn("Q1"), LLMScript.turn("Q2")], %{reattach_ms: 1000})

    Process.exit(owner, :kill)
    Process.sleep(20)
    assert Session.whereis(id)

    assert {:ok, view} = Assessment.attach(id, same_link())
    assert %{status: :awaiting_answer, question: %{text: "Q1", number: 1}, report: nil} = view
    assert view.meta == @meta

    # Events now come to the new owner.
    :ok = Assessment.answer(id, "One.")
    assert_event(id, {:question, %{text: "Q2"}})
  end

  test "without a new owner the session stops after the grace period" do
    {id, owner} = owned_session([LLMScript.turn("Q1")], %{reattach_ms: 50})
    Process.exit(owner, :kill)
    Process.sleep(10)
    assert Session.whereis(id)
    assert gone?(id)
  end

  test "with no grace period the session stops with its owner" do
    {id, owner} = owned_session([LLMScript.turn("Q1")], %{reattach_ms: 0})
    Process.exit(owner, :kill)
    assert gone?(id)
  end

  test "attaching to a session for another link, or one that has gone, is refused" do
    {id, owner} = owned_session([LLMScript.turn("Q1")], %{reattach_ms: 1000})
    assert {:error, :not_found} = Assessment.attach(id, &(&1[:link_id] == 7))
    assert {:error, :not_found} = Assessment.attach("no-such-session-id-00000", same_link())

    # A refused attach leaves the owner in place.
    Process.exit(owner, :kill)
    Process.sleep(10)
    assert {:ok, _} = Assessment.attach(id, same_link())
  end

  test "events while no owner is attached are dropped; attach reports the state instead" do
    {id, owner} =
      owned_session([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)], %{
        reattach_ms: 1000
      })

    # Answer through a third process that is not the owner, then lose the owner.
    :ok = Assessment.answer(id, "One.")
    Process.exit(owner, :kill)

    view =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        Process.sleep(10)
        {:ok, view} = Assessment.attach(id, same_link())
        if view.status == :done, do: {:halt, view}, else: {:cont, view}
      end)

    assert %{status: :done, report: %Report{}, question: nil} = view
  end

  test "download/1 gives the report and meta once written, and not before" do
    {id, _} = start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
    assert_event(id, {:question, _})
    assert {:error, :not_ready} = Assessment.download(id)

    :ok = Assessment.answer(id, "One.")
    assert_event(id, {:report, report})
    assert {:ok, ^report, %{}} = Assessment.download(id)
    assert {:error, :not_found} = Assessment.download("no-such-session-id-00000")
  end

  test "when the report expires the owner is told before the session stops" do
    {id, _} =
      start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)],
        limits: %{report_ttl_ms: 50}
      )

    assert_event(id, {:question, _})
    :ok = Assessment.answer(id, "One.")
    assert_event(id, {:report, _})
    assert_event(id, :expired, 1000)
    assert gone?(id)
  end

  test "the question on screen is redacted from the session's status" do
    {id, _} = start!([LLMScript.turn("QUESTION-MARKER about pricing")])
    assert_event(id, {:question, _})
    status = id |> Session.whereis() |> :sys.get_status() |> inspect(limit: :infinity)
    refute status =~ "QUESTION-MARKER"
  end
end
