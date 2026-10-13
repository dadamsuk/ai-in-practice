defmodule AiInPracticeWeb.AssessmentPrivacyTest do
  # PRD §10: nothing a person writes, nor their reports, nor their link
  # token or session id, reaches a log. Not async: captures every process's
  # logs and sets the model client.
  use AiInPracticeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AiInPractice.LinksFixtures

  alias AiInPractice.{GlobalLog, LLMScript}

  @moduletag :privacy

  setup do
    llm = Application.get_env(:ai_in_practice, :llm)
    on_exit(fn -> Application.put_env(:ai_in_practice, :llm, llm) end)
    {recruiter, _} = recruiter_link_fixture()
    {_link, token} = candidate_link_fixture(recruiter)
    %{token: token}
  end

  defp await(view, selector) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      if has_element?(view, selector),
        do: {:halt, :ok},
        else: Process.sleep(10) && {:cont, nil}
    end) || flunk("#{selector} never appeared")
  end

  test "a whole session, with its downloads, logs no answer, report, token or session id", %{
    conn: conn,
    token: token
  } do
    {client, _} =
      LLMScript.client([LLMScript.turn("QUESTION-MARKER-1"), LLMScript.turn("", [], close: true)])

    Application.put_env(:ai_in_practice, :llm, client)
    test = self()

    log =
      GlobalLog.capture(:debug, fn ->
        {:ok, view, _} = live(conn, ~p"/a/#{token}")
        view |> form("#begin-form") |> render_submit()
        await(view, "#question")

        view
        |> form("#answer-form", %{answer: "ANSWER-MARKER we cut invoice errors by a third"})
        |> render_submit()

        await(view, "#candidate-report")
        [_, id] = Regex.run(~r/data-session="([^"]+)"/, render(view))
        send(test, {:session, id})

        for audience <- ~w(candidate assessor) do
          assert build_conn() |> get(~p"/reports/#{id}/#{audience}") |> response(200)
        end
      end)

    assert_received {:session, id}
    assert log =~ "HANDLE EVENT"
    refute log =~ "ANSWER-MARKER"
    refute log =~ "invoice errors"
    refute log =~ "They described their own use of AI"
    refute log =~ token
    refute log =~ id
  end

  test "a LiveView crash while reports are on screen logs none of them", %{
    conn: conn,
    token: token
  } do
    {client, _} =
      LLMScript.client([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])

    Application.put_env(:ai_in_practice, :llm, client)
    {:ok, view, _} = live(conn, ~p"/a/#{token}")
    view |> form("#begin-form") |> render_submit()
    await(view, "#question")

    view
    |> form("#answer-form", %{answer: "CRASH-ANSWER-MARKER pricing paper"})
    |> render_submit()

    await(view, "#candidate-report")
    [_, id] = Regex.run(~r/data-session="([^"]+)"/, render(view))

    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)

    log =
      GlobalLog.capture(:debug, fn ->
        # No clause handles this event, so the LiveView crashes with its
        # assigns (the reports) in the failing call.
        send(view.pid, {AiInPractice.Assessment, id, {:unexpected, "CRASH-MESSAGE-MARKER"}})
        assert_receive {:DOWN, ^ref, :process, _, _}, 1000
      end)

    assert log =~ "AssessmentLive" or log =~ "crash" or log =~ "terminating"
    refute log =~ "CRASH-ANSWER-MARKER"
    refute log =~ "CRASH-MESSAGE-MARKER"
    refute log =~ "They described their own use of AI"
    refute log =~ token
  end
end
