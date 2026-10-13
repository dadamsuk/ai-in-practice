defmodule AiInPracticeWeb.AssessmentLiveTest do
  # Not async: each test sets the model client and session limits globally,
  # and the session's processes share the sandbox.
  use AiInPracticeWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import AiInPractice.LinksFixtures
  import AiInPractice.SessionHelpers, only: [gone?: 1]

  alias AiInPractice.{Assessment, Links, LLMScript, Reading, Repo}
  alias AiInPractice.Assessment.Session
  alias AiInPractice.Links.{AssessmentLink, Token}
  alias AiInPractice.LLM.Fake

  setup do
    llm = Application.get_env(:ai_in_practice, :llm)
    limits = Application.get_env(:ai_in_practice, :assessment_limits)

    on_exit(fn ->
      Application.put_env(:ai_in_practice, :llm, llm)
      Application.put_env(:ai_in_practice, :assessment_limits, limits)
    end)

    {recruiter, _} = recruiter_link_fixture(%{firm_name: "Northgate Search"})
    %{recruiter: recruiter}
  end

  defp use_script(script) do
    {client, agent} = LLMScript.client(script)
    Application.put_env(:ai_in_practice, :llm, client)
    agent
  end

  # Each request waits, in the session's model-call task, until the test
  # sends it `:go`; the test is told `{:requested, task}` first.
  defp gated(reply) do
    test = self()

    fn _request ->
      send(test, {:requested, self()})

      receive do
        :go -> reply
      end
    end
  end

  defp use_limits(limits) do
    current = Application.get_env(:ai_in_practice, :assessment_limits, %{})
    Application.put_env(:ai_in_practice, :assessment_limits, Map.merge(current, limits))
  end

  # Waits for the view to show `selector` (the session answers from its
  # own processes).
  defp await(view, selector, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(view, selector, deadline)
  end

  defp do_await(view, selector, deadline) do
    cond do
      has_element?(view, selector) ->
        view

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{selector} never appeared:\n#{render(view)}")

      true ->
        Process.sleep(10)
        do_await(view, selector, deadline)
    end
  end

  defp link_status(link), do: Repo.get!(AssessmentLink, link.id).status

  defp session_id(view) do
    view
    |> element("#live-session")
    |> render()
    |> then(&Regex.run(~r/data-session="([^"]+)"/, &1))
    |> List.last()
  end

  defp node_text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp candidate(recruiter, group \\ :finance), do: candidate_link_fixture(recruiter, group)

  defp begin(conn, token) do
    {:ok, view, _html} = live(conn, ~p"/a/#{token}")
    view |> form("#begin-form") |> render_submit()
    view
  end

  defp answer(view, text) do
    view |> form("#answer-form", %{answer: text}) |> render_submit()
  end

  describe "start screen" do
    test "is short: three essentials up front, the rest under More details", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      {:ok, view, _html} = live(conn, ~p"/a/#{token}")

      assert has_element?(view, "#essentials > li", "Be specific.")
      assert has_element?(view, "#be-specific", "what you did, which tools, and what happened")
      assert has_element?(view, "#essentials > li", "You have one attempt.")
      assert has_element?(view, "#essentials > li", "Nothing you write is kept")

      assert view
             |> element("#essentials")
             |> render()
             |> then(&Regex.scan(~r/<li/, &1))
             |> length() == 3

      # The fuller text is all still there, folded away and closed.
      assert has_element?(view, "details#more-about:not([open]) > summary", "More details")
      assert has_element?(view, "details#more-about #before-you-begin", "20 to 25 minutes")
      assert has_element?(view, "details#more-about", "no scores")
      assert has_element?(view, "details#more-about", "less accurate")
      assert has_element?(view, "details#more-handling:not([open]) > summary", "More details")
      assert has_element?(view, "details#more-handling #data-handling", "zero data retention")

      # The legal links stay in view, outside the folds.
      refute has_element?(view, "details #legal")
      assert has_element?(view, "#legal a[href='/privacy']")
    end

    test "the answer box always asks for a real example and detail", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      assert has_element?(view, "#answer-help #be-specific-hint", "Give a real example")
    end

    test "the role drop-down sits in a .select box, which draws its arrow", %{conn: conn} do
      {_link, token} = individual_link_fixture()
      {:ok, view, _html} = live(conn, ~p"/a/#{token}")
      assert has_element?(view, "#begin-form .select > select[name='role_group']")
    end

    test "a recruiter's link shows who sent it, the role group and what to expect", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter, :people)
      {:ok, view, html} = live(conn, ~p"/a/#{token}")

      assert view |> element("#sender") |> render() =~ "Northgate Search"
      assert view |> element("#sender") |> render() =~ "whether you have started and completed"
      assert view |> element("#role-group") |> render() =~ "People"
      assert html =~ "makes no decision about you"
      assert html =~ "20 to 25 minutes"
      assert html =~ "one attempt"
      assert html =~ "figures as ranges"
      assert view |> element("#data-handling") |> render() =~ "never written to disk"

      for party <- ["Cloudflare", "OpenRouter", "the AI model&#39;s provider"] do
        assert view |> element("#data-handling") |> render() =~ party
      end

      # The privacy notice and terms open in a new tab, so reading them
      # cannot end a conversation.
      assert has_element?(view, ~s(#legal a[href="/privacy"][target="_blank"]), "privacy notice")
      assert has_element?(view, ~s(#legal a[href="/terms"][target="_blank"]), "terms")
      assert has_element?(view, ~s(#running-foot a[href="/privacy"][target="_blank"]))
      refute has_element?(view, "select")
      refute html =~ ~r/interview|verified|score:/i

      # Opening the start screen does not use the link up.
      assert link_status(link) == :unused
    end

    test "an individual link asks for a role group and refuses to begin without one", %{
      conn: conn
    } do
      {link, token} = individual_link_fixture()
      {:ok, view, html} = live(conn, ~p"/a/#{token}")

      refute has_element?(view, "#sender")
      assert html =~ "your role group"

      html = view |> form("#begin-form", %{role_group: ""}) |> render_submit()
      assert html =~ "Choose the role group closest to yours."
      assert has_element?(view, "#begin-form")

      # A forged value is refused like a missing one.
      html = render_submit(view, "begin", %{"role_group" => "not-a-group"})
      assert html =~ "Choose the role group closest to yours."
      html = render_submit(view, "begin", %{})
      assert html =~ "Choose the role group closest to yours."
      assert link_status(link) == :unused
    end

    test "begins with the chosen role group, and records it when the link is used", %{
      conn: conn
    } do
      {link, token} = individual_link_fixture()
      {:ok, view, _} = live(conn, ~p"/a/#{token}")
      view |> form("#begin-form", %{role_group: "technology_product"}) |> render_submit()
      await(view, "#question")

      assert %{status: :started, role_group: :technology_product, mode: :text} =
               Repo.get!(AssessmentLink, link.id)
    end

    test "a link used in another tab after this one opened leads to the dead end", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      {:ok, view, _} = live(conn, ~p"/a/#{token}")
      {:ok, _} = Links.mark_started(link)

      html = view |> form("#begin-form") |> render_submit()
      assert html =~ "This link cannot be opened"
    end
  end

  describe "conversation" do
    test "a full session: questions one at a time, then generating, then both reports", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      assert view |> element("#question") |> render() =~ "last piece of real work"
      assert has_element?(view, "#question[tabindex='-1'][phx-hook]")
      assert has_element?(view, "label[for='answer-1']", "your answer")
      assert has_element?(view, "#progress[aria-valuenow='0']")
      assert has_element?(view, "#finish")
      assert link_status(link) == :started

      for n <- 1..5 do
        answer(view, "Answer #{n}: I used AI to draft a pricing paper and checked it.")

        if n < 5 do
          await(view, "#question[data-number='#{n + 1}']")
        end
      end

      await(view, "#candidate-report")
      html = render(view)

      assert link_status(link) == :completed
      assert html =~ "Nothing is kept"
      assert html =~ "both reports are gone for good"
      assert has_element?(view, "#candidate-report", "What you are doing well")
      assert has_element?(view, "#assessor-report", "Questions to ask in person")
      assert has_element?(view, "#assessor-report", "conversation starter")
      assert has_element?(view, "#assessor-report blockquote", "I used AI to draft")

      id = session_id(view)
      assert has_element?(view, "#downloads a[href='/reports/#{id}/candidate']")
      assert has_element?(view, "#downloads a[href='/reports/#{id}/assessor']")

      # Internal levels and confidence are never shown, nor any praise.
      text = view |> element("#candidate-report") |> render()
      assessor = view |> element("#assessor-report") |> render()

      for word <- ~w(developing capable advanced insufficient_evidence) do
        refute text =~ word
        refute assessor =~ word
      end

      refute html =~ ~r/great answer|well done|score/i
    end

    test "the link is used only once the first question has arrived", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      test = self()

      use_script([
        fn _request ->
          # Runs in the session's model-call task; wait to be released.
          send(test, {:first_turn_requested, self()})

          receive do
            :go -> LLMScript.turn("Slow first question?")
          end
        end
      ])

      view = begin(conn, token)
      assert_receive {:first_turn_requested, task}, 1000
      assert has_element?(view, "#status", "Your first question is being written.")
      assert link_status(link) == :unused

      send(task, :go)
      await(view, "#question")
      assert view |> element("#question") |> render() =~ "Slow first question?"
      assert link_status(link) == :started
    end

    test "an empty or over-long answer is refused with a message, keeping the draft", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      html = answer(view, "   ")
      assert html =~ "Write an answer before sending it."
      assert has_element?(view, "textarea[aria-invalid='true']")

      long = String.duplicate("a", 8_001)
      html = answer(view, long)
      assert html =~ "longer than 8,000 characters"
      assert has_element?(view, "#answer-1", long)
      assert has_element?(view, "#question[data-number='1']")
    end

    test "a refused paste shows the quiet note", %{conn: conn, recruiter: recruiter} do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      refute has_element?(view, "#paste-note")
      view |> element("#answer-1") |> render_hook("paste_refused", %{})
      assert has_element?(view, "#paste-note", "Pasting is turned off here")
    end

    test "the answer box carries the paste hook and the page the session hook", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      assert view |> element("#answer-1") |> render() =~ "AnswerBox"
      assert view |> element("#live-session") |> render() =~ "LiveSession"
      assert session_id(view) =~ ~r/\A[A-Za-z0-9_-]{24}\z/
    end

    test "the progress rule fills as areas are covered", %{conn: conn, recruiter: recruiter} do
      {_link, token} = candidate(recruiter)

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("Q2", [:personal_use, :understanding])
      ])

      view = begin(conn, token)
      await(view, "#question")
      assert has_element?(view, "#progress[aria-valuenow='0']")
      refute has_element?(view, ".progress-done")

      answer(view, "One.")
      await(view, "#question[data-number='2']")
      assert has_element?(view, "#progress[aria-valuenow='2']")
      assert view |> render() |> then(&Regex.scan(~r/progress-done/, &1)) |> length() == 2
    end

    test "finish early writes the reports from what was said", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "I use AI for drafting board papers.")
      await(view, "#question[data-number='2']")

      view |> element("#finish") |> render_click()
      await(view, "#candidate-report")
      assert link_status(link) == :completed
    end

    test "finishing before any answer ends with nothing to report", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      view |> element("#finish") |> render_click()
      await(view, "#failed[data-reason='no_answers']")
      assert render(view) =~ "ended before any answers"
      assert render(view) =~ "Northgate Search, who sent it, can send you a new one"
      assert link_status(link) == :started
    end

    test "the 40-minute stop closes the conversation and says so while writing", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      use_limits(%{hard_stop_ms: 300})

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("Q2"),
        fn _request ->
          Process.sleep(500)
          {:ok, Fake.report([])}
        end
      ])

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#time-up")
      assert render(view) =~ "The 40 minutes are up"
      assert render(view) =~ "Writing your reports"

      await(view, "#candidate-report")
      assert has_element?(view, "#time-up", "The 40 minutes were up")
    end
  end

  describe "the question screen's controls" do
    test "send is disabled until there is an answer, and the browser keeps it so", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      assert has_element?(view, "#send[disabled]")
      assert has_element?(view, "#send[phx-mounted*='ignore_attrs']")
      assert has_element?(view, "#answer-1[phx-hook$='AnswerBox'][data-voice='idle']")

      view |> form("#answer-form", %{answer: "   "}) |> render_change()
      assert has_element?(view, "#send[disabled]")

      view |> form("#answer-form", %{answer: "I drafted a paper."}) |> render_change()
      refute has_element?(view, "#send[disabled]")
    end

    test "a sent answer greys the question until the next one arrives", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), gated(LLMScript.turn("Q2"))])

      view = begin(conn, token)
      await(view, "#question")
      refute has_element?(view, "#question.question-answered")

      answer(view, "One.")
      assert_receive {:requested, task}, 1000
      assert has_element?(view, "#question.question-answered", "Q1")
      assert has_element?(view, "#status", "The next question is being written.")

      send(task, :go)
      await(view, "#question[data-number='2']")
      refute has_element?(view, "#question.question-answered")
    end

    test "finish early says the report will be less accurate", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      assert has_element?(view, "#finish + #finish-note", "Your report will be less accurate.")
    end
  end

  describe "writing the reports" do
    setup do
      tau = Application.get_env(:ai_in_practice, :report_progress_tau_ms)
      on_exit(fn -> Application.put_env(:ai_in_practice, :report_progress_tau_ms, tau) end)
    end

    test "a progress bar fills with the time taken, stopping short until the reports come", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("", [], close: true),
        gated({:ok, Fake.report(["One."])})
      ])

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      assert_receive {:requested, task}, 1000

      assert has_element?(view, "#writing-progress[role='progressbar'][aria-valuemax='20']")
      assert has_element?(view, "#writing-progress[aria-valuenow='0']")
      assert has_element?(view, "#writing-progress[aria-label='writing your reports']")
      refute has_element?(view, "#writing-progress .progress-done")

      # A long wait: the bar is nearly full but never complete.
      Application.put_env(:ai_in_practice, :report_progress_tau_ms, 1)
      Process.sleep(5)
      send(view.pid, :writing_tick)
      assert has_element?(view, "#writing-progress[aria-valuenow='19']")
      assert view |> render() |> then(&Regex.scan(~r/progress-done/, &1)) |> length() == 19

      send(task, :go)
      await(view, "#candidate-report")
      refute has_element?(view, "#writing-progress")

      # A tick still on its way after the reports arrive changes nothing.
      send(view.pid, :writing_tick)
      assert has_element?(view, "#candidate-report")
    end

    test "the bar starts empty and moves part-way with a normal pace", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      Application.put_env(:ai_in_practice, :report_progress_tau_ms, 100)

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("Q2"),
        gated({:ok, Fake.report(["One."])})
      ])

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#question[data-number='2']")
      view |> element("#finish") |> render_click()
      assert_receive {:requested, task}, 1000
      assert has_element?(view, "#writing-progress[aria-valuenow='0']")

      Process.sleep(70)
      send(view.pid, :writing_tick)

      [_, done] =
        Regex.run(~r/aria-valuenow="(\d+)"/, view |> element("#writing-progress") |> render())

      assert String.to_integer(done) in 5..18

      send(task, :go)
      await(view, "#candidate-report")
    end
  end

  describe "a busy model" do
    test "mid-conversation, the answer comes back into the box to send again", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)

      use_script(
        [LLMScript.turn("Q1")] ++
          List.duplicate({:error, :transient}, 3) ++ [LLMScript.turn("Q2")]
      )

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "We cut invoice errors by a third.")
      await(view, "#answer-error")

      assert view |> element("#answer-error") |> render() =~ "could not be sent just now"
      assert view |> element("#question") |> render() =~ "Q1"

      assert view |> element("textarea[name=answer]") |> render() =~
               "We cut invoice errors by a third."

      refute has_element?(view, "#failed")

      answer(view, "We cut invoice errors by a third.")
      await(view, "#question[data-number='2']")
      refute has_element?(view, "#answer-error")
      assert view |> element("textarea[name=answer]") |> render() |> node_text() == ""
    end

    test "the answer given back survives a reconnect", %{conn: conn, recruiter: recruiter} do
      {_link, token} = candidate(recruiter)
      use_limits(%{reattach_ms: 2000})
      use_script([LLMScript.turn("Q1")] ++ List.duplicate({:error, :transient}, 3))

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "Held across a reconnect.")
      await(view, "#answer-error")
      id = session_id(view)

      # A new view attaches to the same session, as after a dropped connection.
      {:ok, view2, _} =
        conn
        |> put_connect_params(%{"attach" => id})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      await(view2, "#answer-error")
      assert view2 |> element("textarea[name=answer]") |> render() =~ "Held across a reconnect."
    end

    test "while writing the reports, it offers to try again and nothing is lost", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)

      use_script(
        [LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)] ++
          List.duplicate({:error, :transient}, 3)
      )

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "The only answer.")
      await(view, "#report-not-written")

      html = view |> element("#report-not-written") |> render()
      assert html =~ "not written yet"
      assert html =~ "nothing is lost"
      refute html =~ ~r/fail|score|test/i
      assert link_status(link) == :started

      view |> element("#retry-report") |> render_click()
      await(view, "#candidate-report")
      assert render(view) =~ "The only answer."
      assert link_status(link) == :completed
    end

    test "a fatal failure mid-conversation still ends it", %{conn: conn, recruiter: recruiter} do
      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), {:error, :fatal}])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#failed")
      assert render(view) =~ "the conversation has stopped"
    end
  end

  describe "quick sessions" do
    defp quick_link do
      {:ok, link, token} = Links.create_individual_link(%{label: "IND-Q", quick: true})
      {link, token}
    end

    test "the start screen says it is quick and how long it takes", %{conn: conn} do
      {_link, token} = quick_link()
      {:ok, view, html} = live(conn, ~p"/a/#{token}")

      assert view |> element("#quick") |> render() =~ "three or four questions"
      assert html =~ "stops after eight at most"
      refute html =~ "20 to 25 minutes"
      refute html =~ ~r/interview|verified|score:/i
    end

    test "a full link's start screen never mentions quick", %{conn: conn} do
      {_link, token} = individual_link_fixture()
      {:ok, view, html} = live(conn, ~p"/a/#{token}")
      refute has_element?(view, "#quick")
      assert html =~ "20 to 25 minutes"
    end

    test "runs on the quick limits and marks the reports", %{conn: conn} do
      {link, token} = quick_link()
      agent = use_script(for n <- 1..5, do: LLMScript.turn("Q#{n}"))

      {:ok, view, _} = live(conn, ~p"/a/#{token}")
      view |> form("#begin-form", %{role_group: "finance"}) |> render_submit()

      for n <- 1..4 do
        await(view, "#question")
        assert render(view) =~ "Q#{n}"
        answer(view, "Answer #{n}.")
      end

      await(view, "#candidate-report")
      assert render(view) =~ "not a full conversation"
      assert Repo.get!(AssessmentLink, link.id).status == :completed

      turns = agent |> LLMScript.requests() |> Enum.filter(&(&1.purpose == :turn))
      assert length(turns) == 5
      assert List.last(hd(turns).messages).content =~ "aim for 3 to 4"
    end

    test "a full link's reports are not marked quick", %{conn: conn, recruiter: recruiter} do
      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#candidate-report")
      refute render(view) =~ "not a full conversation"
    end

    test "the time-up note gives the quick session's limit", %{conn: conn} do
      {_link, token} = quick_link()
      use_limits(%{hard_stop_ms: 300})

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("Q2"),
        fn _request ->
          Process.sleep(500)
          {:ok, Fake.report([])}
        end
      ])

      {:ok, view, _} = live(conn, ~p"/a/#{token}")
      view |> form("#begin-form", %{role_group: "finance"}) |> render_submit()
      await(view, "#question")
      answer(view, "One.")
      await(view, "#time-up")
      assert render(view) =~ "The 8 minutes are up"
    end
  end

  describe "odds and ends" do
    test "reading picks from the list appear in the candidate report", %{
      conn: conn,
      recruiter: recruiter
    } do
      {:ok, item} =
        Reading.create_item(%{
          title: "Working with AI",
          url: "https://example.com/working",
          areas: [:personal_use],
          note: "Short and practical."
        })

      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#candidate-report")

      assert has_element?(view, "#candidate-report", "Further reading")
      assert has_element?(view, "#candidate-report a[href='#{item.url}']")
      assert has_element?(view, "#candidate-report", "Short and practical.")
      refute has_element?(view, "#assessor-report", "Working with AI")
    end

    test "stray events and messages change nothing", %{conn: conn, recruiter: recruiter} do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      before = render(view)

      render_hook(view, "no-such-event", %{})
      send(view.pid, :something_else)
      send(view.pid, {Assessment, "another-session-id-0000000", {:failed, :fatal}})
      # An answer or finish outside the conversation is ignored too.
      render_submit(view, "begin", %{})

      assert render(view) == before
    end
  end

  describe "errors and unavailable states" do
    test "a spend refusal before the first question: temporarily unavailable, link unused", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      use_script([{:error, :spend_refused}])
      view = begin(conn, token)

      await(view, "#failed")
      html = render(view)
      assert html =~ "not available just now"
      assert html =~ "Your link has not been used"
      assert link_status(link) == :unused
      refute has_element?(view, "#live-session")
    end

    test "any other failure before the first question: try again, link unused", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      use_script([{:error, :fatal}])
      view = begin(conn, token)

      await(view, "#failed")
      assert render(view) =~ "could not begin"
      assert has_element?(view, "#failed a[href='/a/#{token}']", "Try again")
      assert link_status(link) == :unused
    end

    test "a failure mid-session apologises and says the recruiter can replace the link", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), {:error, :spend_refused}])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")

      await(view, "#failed")
      html = render(view)
      assert html =~ "Sorry, the conversation has stopped"
      assert html =~ "Nothing you said has been kept"
      assert html =~ "Northgate Search, who sent it, can send you a new one"
      assert link_status(link) == :started

      # Kind words only: no error class, stack trace or token on screen.
      text = view |> element("#failed") |> render() |> node_text()
      refute text =~ ~r/spend|refused|stacktrace|\*\*|#{token}/i
    end

    test "for an individual link, the replacement comes from David", %{conn: conn} do
      {_link, token} = individual_link_fixture()
      use_script([LLMScript.turn("Q1"), {:error, :fatal}])
      {:ok, view, _} = live(conn, ~p"/a/#{token}")
      view |> form("#begin-form", %{role_group: "finance"}) |> render_submit()
      await(view, "#question")
      answer(view, "One.")

      await(view, "#failed")
      assert render(view) =~ "David at DSC, who sent it, can send you a new one"
    end

    test "reports that cannot be written get the apology screen", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("", [], close: true),
        {:ok, %{"summary" => "only"}},
        {:ok, %{"summary" => "only"}}
      ])

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")

      await(view, "#failed[data-reason='report_invalid']")
      assert render(view) =~ "your reports could not be written"
      assert link_status(link) == :started
    end

    test "when the reports' hour is up the page says so and downloads stop", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      use_limits(%{report_ttl_ms: 200})
      use_script([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#candidate-report")
      id = session_id(view)

      await(view, "#session-ended")
      assert render(view) =~ "Your reports are no longer available"
      refute has_element?(view, "#candidate-report")
      assert build_conn() |> get(~p"/reports/#{id}/candidate") |> response(404)
    end

    test "a session that dies unexpectedly shows the apology", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")

      id = session_id(view)
      pid = Session.whereis(id)
      Process.exit(pid, :kill)

      await(view, "#failed")
      assert render(view) =~ "Sorry, the conversation has stopped"
    end

    test "two tabs on one link: the first to show a question wins, the other dead-ends", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      {:ok, one, _} = live(conn, ~p"/a/#{token}")
      {:ok, two, _} = live(build_conn(), ~p"/a/#{token}")

      one |> form("#begin-form") |> render_submit()
      await(one, "#question")
      two |> form("#begin-form") |> render_submit()

      await(two, "#dead-end")
      assert has_element?(one, "#question")
    end
  end

  describe "the race to use a link" do
    test "two tabs both begin: the first to show a question uses the link, the other stops", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      use_script([gated(LLMScript.turn("Q-one")), gated(LLMScript.turn("Q-two"))])

      {:ok, one, _} = live(conn, ~p"/a/#{token}")
      {:ok, two, _} = live(build_conn(), ~p"/a/#{token}")
      one |> form("#begin-form") |> render_submit()
      two |> form("#begin-form") |> render_submit()
      assert_receive {:requested, first}, 1000
      assert_receive {:requested, second}, 1000
      assert link_status(link) == :unused

      send(first, :go)
      send(second, :go)

      wait = fn view ->
        Enum.find_value(1..200, fn _ ->
          cond do
            has_element?(view, "#question") -> :question
            has_element?(view, "#dead-end") -> :dead_end
            true -> Process.sleep(10) && nil
          end
        end)
      end

      assert Enum.sort([wait.(one), wait.(two)]) == [:dead_end, :question]
      assert link_status(link) == :started
    end
  end

  describe "reconnecting" do
    setup do
      use_limits(%{reattach_ms: 2000})
      :ok
    end

    test "a reconnect with the session id carries on with the same question", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      id = session_id(view)

      {:ok, again, html} =
        conn
        |> put_connect_params(%{"attach" => id})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      assert html =~ "last piece of real work"
      assert session_id(again) == id

      # The first view's exit no longer ends the session.
      GenServer.stop(view.pid)
      Process.sleep(50)
      assert Session.whereis(id)

      answer(again, "Carrying on after a reconnect.")
      await(again, "#question[data-number='2']")
      assert link_status(link) == :started
    end

    test "closing the page ends the session at once, whatever the grace period", %{
      conn: conn,
      recruiter: recruiter
    } do
      use_limits(%{reattach_ms: 60_000})
      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#candidate-report")
      id = session_id(view)

      assert view |> element("#live-session") |> render() =~ "LiveSession"

      # The hook's beacon on pagehide.
      assert build_conn() |> post(~p"/sessions/#{id}/end") |> response(204)
      assert gone?(id)
      await(view, "#failed")
      assert build_conn() |> get(~p"/reports/#{id}/candidate") |> response(404)
    end

    test "a session left without its page stops after the grace period", %{
      conn: conn,
      recruiter: recruiter
    } do
      use_limits(%{reattach_ms: 100})
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      id = session_id(view)

      GenServer.stop(view.pid)
      Process.sleep(30)
      assert Session.whereis(id)
      assert gone?(id)
    end

    test "a reconnect whose session has gone says the conversation was interrupted", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      id = session_id(view)
      Assessment.stop(id)

      {:ok, again, html} =
        conn
        |> put_connect_params(%{"attach" => id})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      assert html =~ "The conversation was interrupted"
      assert html =~ "Northgate Search, who sent it, can send you a new one"
      assert has_element?(again, "#session-ended")
    end

    test "a session id from another link does not attach", %{conn: conn, recruiter: recruiter} do
      {_, token} = candidate(recruiter)
      {_, other_token} = candidate(recruiter)
      view = begin(conn, token)
      await(view, "#question")
      id = session_id(view)

      {:ok, _other, html} =
        conn
        |> put_connect_params(%{"attach" => id})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => other_token})

      # The other link is unused, so it gets its own start screen.
      assert html =~ "Begin the conversation"
      refute html =~ "last piece of real work"
    end

    test "a reconnect while the next question is being written waits for it", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), gated(LLMScript.turn("Q2 after reconnect"))])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      assert_receive {:requested, task}, 1000

      {:ok, again, html} =
        conn
        |> put_connect_params(%{"attach" => session_id(view)})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      assert html =~ "The next question is being written."
      send(task, :go)
      await(again, "#question[data-number='2']")
      assert render(again) =~ "Q2 after reconnect"
    end

    test "a reconnect before the first question shows it arriving", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)
      use_script([gated(LLMScript.turn("First after reconnect"))])
      view = begin(conn, token)
      assert_receive {:requested, task}, 1000

      {:ok, again, html} =
        conn
        |> put_connect_params(%{"attach" => session_id(view)})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      assert html =~ "Your first question is being written."
      GenServer.stop(view.pid)
      send(task, :go)
      await(again, "#question")
      assert link_status(link) == :started
    end

    test "a reconnect while the reports are being written waits for them", %{
      conn: conn,
      recruiter: recruiter
    } do
      {link, token} = candidate(recruiter)

      use_script([
        LLMScript.turn("Q1"),
        LLMScript.turn("", [], close: true),
        gated({:ok, Fake.report(["One."])})
      ])

      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      assert_receive {:requested, task}, 1000

      {:ok, again, html} =
        conn
        |> put_connect_params(%{"attach" => session_id(view)})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      assert html =~ "Writing your reports"
      GenServer.stop(view.pid)
      send(task, :go)
      await(again, "#candidate-report")
      assert link_status(link) == :completed
    end

    test "a reconnect for a link that no longer exists dead-ends", %{conn: conn} do
      {:ok, _view, html} =
        conn
        |> put_connect_params(%{"attach" => "AAAAAAAAAAAAAAAAAAAAAAAA"})
        |> live_isolated(AiInPracticeWeb.AssessmentLive,
          session: %{"token" => Token.generate()}
        )

      assert html =~ "This link cannot be opened"
    end

    test "a reconnect while the reports are on screen shows them again", %{
      conn: conn,
      recruiter: recruiter
    } do
      {_link, token} = candidate(recruiter)
      use_script([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      view = begin(conn, token)
      await(view, "#question")
      answer(view, "One.")
      await(view, "#candidate-report")

      {:ok, again, _html} =
        conn
        |> put_connect_params(%{"attach" => session_id(view)})
        |> live_isolated(AiInPracticeWeb.AssessmentLive, session: %{"token" => token})

      assert has_element?(again, "#assessor-report")
    end
  end
end
