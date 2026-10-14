defmodule AiInPractice.Assessment.SessionTest do
  use ExUnit.Case, async: true

  import AiInPractice.SessionHelpers
  import ExUnit.CaptureLog

  alias AiInPractice.Assessment
  alias AiInPractice.Assessment.{Report, Session}
  alias AiInPractice.LLMScript
  alias AiInPractice.Rubric

  @all Rubric.areas()

  defp slow(entry, ms) do
    fn _request ->
      Process.sleep(ms)
      entry
    end
  end

  defp answer_count(request) do
    request.messages
    |> List.last()
    |> Map.fetch!(:content)
    |> then(&length(Regex.scan(~r/<answer>/, &1)))
  end

  describe "start" do
    test "the first question arrives as an event, marked first" do
      {id, _} = start!([LLMScript.turn("What did you last use AI for?")])

      assert_event(
        id,
        {:question,
         %{
           text: "What did you last use AI for?",
           number: 1,
           first?: true,
           kind: :main,
           covered: 0,
           done: 0,
           steps: 14
         }}
      )
    end

    test "an unknown role group is refused" do
      assert {:error, :unknown_role_group} =
               Assessment.start(:astronaut, llm: {AiInPractice.LLM.Fake, []})
    end

    test "the role group may be given as a string" do
      assert {:ok, id} =
               Assessment.start("board_ned", llm: {AiInPractice.LLM.Fake, []}, reading: [])

      assert_event(id, {:question, %{first?: true}})
      Assessment.stop(id)
    end

    test "the session id has nothing to do with any link token" do
      {id, _} = start!([])
      assert byte_size(id) == 24
      assert id =~ ~r/\A[A-Za-z0-9_-]+\z/
    end
  end

  describe "quick sessions" do
    test "limits/1: the full session's are unchanged, the quick one's are short" do
      full = Assessment.limits()
      assert full == Assessment.limits(false)
      assert full.aim_main_questions == {10, 14}
      assert {full.min_main_questions, full.max_main_questions} == {8, 14}
      assert full.hard_stop_ms == :timer.minutes(40)

      quick = Assessment.limits(true)
      assert quick.aim_main_questions == {3, 4}
      assert {quick.min_main_questions, quick.max_main_questions} == {3, 4}
      assert quick.max_turns == 6
      assert quick.target_ms == :timer.minutes(3)
      assert quick.hard_stop_ms == :timer.minutes(8)
      # Limits a quick session doesn't change come from the full session.
      assert quick.max_answer_chars == full.max_answer_chars
      assert quick.report_ttl_ms == full.report_ttl_ms
    end

    test "a quick session closes after four main questions and tells the model so" do
      turns = for n <- 1..5, do: LLMScript.turn("Q#{n}")
      {id, agent} = start!(turns, quick: true)

      for n <- 1..4 do
        assert_event(id, {:question, %{text: "Q" <> _, number: ^n}})
        :ok = Assessment.answer(id, "Answer #{n}.")
      end

      assert_event(id, {:closed, :max_questions})
      assert_event(id, {:report, %Report{}})

      [first | _] = LLMScript.requests(agent)
      note = List.last(first.messages).content
      assert note =~ "of about 3."
      assert note =~ "aim for 3 to 4; do not close before 3"
      assert note =~ "never more than 4"
    end

    test "the :limits option still overrides a quick session's limits" do
      {id, agent} = start!([LLMScript.turn("Q1")], quick: true, limits: %{target_ms: 60_000})
      assert_event(id, {:question, %{text: "Q1"}})
      [first] = LLMScript.requests(agent)
      assert List.last(first.messages).content =~ "of about 1."
    end

    test "a full session's progress note keeps the original wording" do
      {id, agent} = start!([LLMScript.turn("Q1")])
      assert_event(id, {:question, %{text: "Q1"}})
      [first] = LLMScript.requests(agent)

      assert List.last(first.messages).content =~
               "Main questions asked: 0 (aim for 10 to 14; do not close before 8 unless told to; never more than 14)."
    end
  end

  describe "progress (#800)" do
    test "one segment per main question at the top of the aim" do
      assert Session.progress_steps(Session.limits()) == 14
      assert Session.progress_steps(Session.limits(true)) == 4
    end

    test "a segment fills for each main question answered, whatever the coverage" do
      limits = Session.limits()
      assert Session.progress_done(0, 0, limits) == 0
      assert Session.progress_done(1, 0, limits) == 1
      assert Session.progress_done(9, 0, limits) == 9
    end

    test "coverage moves it further when it is ahead of the questions" do
      limits = Session.limits()
      # Two of five areas: 2 * 14 / 5, rounded down.
      assert Session.progress_done(1, 2, limits) == 5
      assert Session.progress_done(7, 2, limits) == 7
    end

    test "the last segment waits for the conversation to close" do
      assert Session.progress_done(14, 0, Session.limits()) == 13
      assert Session.progress_done(20, 5, Session.limits()) == 13
      assert Session.progress_done(4, 5, Session.limits(true)) == 3
    end

    test "each question carries how far through it is; a follow-up does not move it" do
      {id, _} =
        start!([
          LLMScript.turn("Q1"),
          LLMScript.turn("Why?", [], kind: "follow_up"),
          LLMScript.turn("Q2")
        ])

      assert_event(id, {:question, %{text: "Q1", done: 0, steps: 14}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:question, %{text: "Why?", done: 1}})
      :ok = Assessment.answer(id, "Because.")
      assert_event(id, {:question, %{text: "Q2", done: 1}})
    end

    test "a quick session has four segments" do
      {id, _} = start!([LLMScript.turn("Q1")], quick: true)
      assert_event(id, {:question, %{done: 0, steps: 4}})
    end
  end

  describe "put_meta/2" do
    test "merges into the meta the session hands back" do
      {client, _} = LLMScript.client([LLMScript.turn("Q1")])

      {:ok, id} =
        Assessment.start(:finance, llm: client, reading: [], meta: %{mode: :text, link_id: 7})

      assert_event(id, {:question, _})
      assert :ok = Assessment.put_meta(id, %{mode: :voice})
      assert {:ok, %{meta: %{mode: :voice, link_id: 7}}} = Assessment.attach(id, fn _ -> true end)
    end

    test "a session that has gone is not found" do
      assert Assessment.put_meta("no-such-session", %{mode: :voice}) == {:error, :not_found}
    end
  end

  describe "the turn loop" do
    test "coverage closes the conversation, but not before the minimum number of main questions" do
      {id, agent} =
        start!(
          [LLMScript.turn("Q1"), LLMScript.turn("Q2", @all), LLMScript.turn("Q3", @all)],
          limits: %{min_main_questions: 2}
        )

      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "First answer about drafting a board paper.")
      # Everything covered after one main question: keep going.
      assert_event(id, {:question, %{text: "Q2", covered: 5}})
      :ok = Assessment.answer(id, "Second answer about the pricing pilot.")
      assert_event(id, {:closed, :covered})
      assert_event(id, {:report, %Report{role_group: :finance}})
      refute_event(id, {:question, _})

      # The report call had both answers.
      report_request = agent |> LLMScript.requests() |> List.last()
      assert report_request.purpose == :report
      assert answer_count(report_request) == 2
      assert {:ok, %Report{}} = Assessment.report(id)
    end

    test "the model closing ends the conversation even below the minimum" do
      {id, _} = start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "An answer.")
      assert_event(id, {:closed, :covered})
      assert_event(id, {:report, _})
    end

    test "the turn prompt carries the transcript and progress so far" do
      {id, agent} = start!([LLMScript.turn("Q1", [:personal_use]), LLMScript.turn("Q2")])
      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "  An answer with spaces.  ")
      assert_event(id, {:question, %{text: "Q2", number: 2, first?: false, covered: 1}})

      [_, second] = LLMScript.requests(agent)
      content = List.last(second.messages).content
      assert content =~ "<answer>\nAn answer with spaces.\n</answer>"
      assert content =~ "Areas you judged covered: Personal use (personal_use)."
      assert content =~ "Main questions asked: 1"
    end

    test "a follow-up after a follow-up counts as a main question" do
      {id, _} =
        start!([
          LLMScript.turn("Q1"),
          LLMScript.turn("Q2", [], kind: "follow_up"),
          LLMScript.turn("Q3", [], kind: "follow_up")
        ])

      assert_event(id, {:question, %{text: "Q1", kind: :main}})
      :ok = Assessment.answer(id, "Vague.")
      assert_event(id, {:question, %{text: "Q2", kind: :follow_up}})
      :ok = Assessment.answer(id, "Still vague.")
      assert_event(id, {:question, %{text: "Q3", kind: :main}})
    end
  end

  describe "limits close gracefully" do
    test "the maximum number of main questions" do
      {id, _} = start!([], limits: %{max_main_questions: 2})
      assert_event(id, {:question, %{number: 1}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:question, %{number: 2}})
      :ok = Assessment.answer(id, "Two.")
      assert_event(id, {:closed, :max_questions})
      assert_event(id, {:report, _})
    end

    test "the maximum number of turns, follow-ups included" do
      {id, _} =
        start!(
          [
            LLMScript.turn("Q1"),
            LLMScript.turn("Q2", [], kind: "follow_up"),
            LLMScript.turn("Q3")
          ],
          limits: %{max_turns: 2}
        )

      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:question, %{text: "Q2"}})
      :ok = Assessment.answer(id, "Two.")
      assert_event(id, {:closed, :max_turns})
      assert_event(id, {:report, _})
    end

    test "the token budget" do
      {id, _} =
        start!([LLMScript.turn("Q1", [], tokens: 1000), LLMScript.turn("Q2", [], tokens: 1000)],
          limits: %{max_tokens: 1500}
        )

      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:closed, :max_tokens})
      refute_event(id, {:question, %{text: "Q2"}})
      assert_event(id, {:report, _})
    end

    test "the hard stop, while waiting for an answer" do
      {id, _} = start!([LLMScript.turn("Q1"), LLMScript.turn("Q2")], limits: %{hard_stop_ms: 300})
      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:question, %{text: "Q2"}})
      assert_event(id, {:closed, :time_limit}, 1000)
      assert_event(id, {:report, _})
      assert {:error, :not_waiting} = Assessment.answer(id, "Too late.")
    end

    test "the hard stop, while a model call is in flight, abandons the call" do
      {id, agent} =
        start!([LLMScript.turn("Q1"), slow(LLMScript.turn("Q2"), 2000)],
          limits: %{hard_stop_ms: 300}
        )

      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:closed, :time_limit}, 1000)
      assert_event(id, {:report, _})
      refute_event(id, {:question, %{text: "Q2"}})
      assert agent |> LLMScript.requests() |> List.last() |> Map.get(:purpose) == :report
    end
  end

  describe "finish early" do
    test "closes and writes the report from the answers given, dropping the unanswered question" do
      {id, agent} = start!([LLMScript.turn("Q1"), LLMScript.turn("Q2")])
      assert_event(id, {:question, %{text: "Q1"}})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:question, %{text: "Q2"}})

      assert :ok = Assessment.finish_early(id)
      assert_event(id, {:closed, :finished_early})
      assert_event(id, {:report, _})

      report_request = agent |> LLMScript.requests() |> List.last()
      assert answer_count(report_request) == 1
      refute List.last(report_request.messages).content =~ "Q2"
    end

    test "before any answer, there is nothing to report and the session ends" do
      {id, _} = start!([LLMScript.turn("Q1")])
      assert_event(id, {:question, _})

      capture_log(fn -> assert :ok = Assessment.finish_early(id) end)
      assert_event(id, {:failed, :no_answers})
      assert gone?(id)
    end

    test "is refused once the conversation is over" do
      {id, _} = start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
      assert_event(id, {:question, _})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:report, _})
      assert {:error, :not_running} = Assessment.finish_early(id)
    end
  end

  describe "answers" do
    test "empty and over-long answers are refused and the question stays" do
      {id, _} =
        start!([LLMScript.turn("Q1"), LLMScript.turn("Q2")], limits: %{max_answer_chars: 10})

      assert_event(id, {:question, _})
      assert {:error, :empty} = Assessment.answer(id, "   \n ")
      assert {:error, :too_long} = Assessment.answer(id, String.duplicate("x", 11))
      assert :ok = Assessment.answer(id, "Ten chars!")
      assert_event(id, {:question, %{text: "Q2"}})
    end

    test "an answer while the next question is being written is refused" do
      {id, _} = start!([LLMScript.turn("Q1"), slow(LLMScript.turn("Q2"), 300)])
      assert_event(id, {:question, _})
      :ok = Assessment.answer(id, "One.")
      assert {:error, :not_waiting} = Assessment.answer(id, "Two.")
      assert_event(id, {:question, %{text: "Q2"}})
    end

    test "the report is not ready during the conversation" do
      {id, _} = start!([LLMScript.turn("Q1")])
      assert_event(id, {:question, _})
      assert {:error, :not_ready} = Assessment.report(id)
    end

    test "calls to a session that has gone are :not_found" do
      assert {:error, :not_found} = Assessment.answer("no-such-session", "x")
      assert {:error, :not_found} = Assessment.finish_early("no-such-session")
      assert {:error, :not_found} = Assessment.report("no-such-session")
      assert :ok = Assessment.stop("no-such-session")
    end
  end

  describe "model failures" do
    test "a transient failure is retried and the conversation carries on" do
      {id, agent} = start!([{:error, :transient}, {:error, :transient}, LLMScript.turn("Q1")])
      capture_log(fn -> assert_event(id, {:question, %{text: "Q1", first?: true}}) end)
      assert LLMScript.calls(agent) == 3
    end

    test "a persistent failure surfaces an error class and the session ends with no question shown" do
      {id, agent} = start!(List.duplicate({:error, :transient}, 3))
      capture_log(fn -> assert_event(id, {:failed, :transient}) end)
      refute_event(id, {:question, _})
      assert LLMScript.calls(agent) == 3
      assert gone?(id)
    end

    test "a spend refusal at the start is not retried and no question is shown" do
      {id, agent} = start!([{:error, :spend_refused}])
      capture_log(fn -> assert_event(id, {:failed, :spend_refused}) end)
      refute_event(id, {:question, _})
      assert LLMScript.calls(agent) == 1
    end

    test "a fatal or spend failure mid-conversation still ends the session" do
      for class <- [:fatal, :spend_refused] do
        {id, _} = start!([LLMScript.turn("Q1"), {:error, class}])
        assert_event(id, {:question, _})
        capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
        assert_event(id, {:failed, ^class})
        refute_event(id, {:answer_not_sent, _})
        assert gone?(id)
      end
    end

    test "a busy model mid-conversation gives the answer back, and sending it again carries on" do
      # Rate limits are retried three times, transient failures twice, by LLM.complete.
      for {class, tries} <- [rate_limited: 4, transient: 3] do
        script =
          [LLMScript.turn("Q1"), LLMScript.turn("Q2")]
          |> List.insert_at(1, List.duplicate({:error, class}, tries))
          |> List.flatten()

        {id, agent} = start!(script)
        assert_event(id, {:question, %{text: "Q1", number: 1}})
        capture_log(fn -> :ok = Assessment.answer(id, "First go.") end)

        assert_event(
          id,
          {:answer_not_sent, %{question: %{text: "Q1", number: 1}, answer: "First go."}}
        )

        assert is_pid(Session.whereis(id))
        assert {:error, :not_ready} = Assessment.report(id)

        # Waiting for the same question again, with the answer held for a reconnect.
        assert {:ok, %{status: :awaiting_answer, question: %{text: "Q1"}, unsent: "First go."}} =
                 Session.attach(id, fn _ -> true end)

        :ok = Assessment.answer(id, "Second go.")
        assert_event(id, {:question, %{text: "Q2", number: 2}})

        # The transcript holds the second answer only.
        last = agent |> LLMScript.requests() |> List.last()
        assert answer_count(last) == 1
        assert List.last(last.messages).content =~ "Second go."
        refute List.last(last.messages).content =~ "First go."

        assert {:ok, %{unsent: nil}} = Session.attach(id, fn _ -> true end)
        Assessment.stop(id)
      end
    end

    test "a busy model can give the same answer back more than once" do
      script =
        [LLMScript.turn("Q1")] ++
          List.duplicate({:error, :transient}, 6) ++ [LLMScript.turn("Q2")]

      {id, _} = start!(script)
      assert_event(id, {:question, %{text: "Q1"}})

      for _ <- 1..2 do
        capture_log(fn -> :ok = Assessment.answer(id, "Again.") end)
        assert_event(id, {:answer_not_sent, %{answer: "Again."}})
      end

      :ok = Assessment.answer(id, "Again.")
      assert_event(id, {:question, %{text: "Q2"}})
    end

    test "a busy model before the first question still ends the session: there is no answer to keep" do
      {id, _} = start!(List.duplicate({:error, :rate_limited}, 4))
      capture_log(fn -> assert_event(id, {:failed, :rate_limited}) end)
      refute_event(id, {:answer_not_sent, _})
      assert gone?(id)
    end

    test "a busy model while writing the report keeps the answers, and retry_report tries again" do
      script =
        [LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)] ++
          List.duplicate({:error, :transient}, 3)

      {id, agent} = start!(script)
      assert_event(id, {:question, _})
      assert {:error, :not_waiting} = Assessment.retry_report(id)
      capture_log(fn -> :ok = Assessment.answer(id, "Only answer.") end)
      assert_event(id, {:closed, :covered})
      capture_log(fn -> assert_event(id, {:report_not_written, :transient}) end)

      assert is_pid(Session.whereis(id))
      assert {:error, :not_ready} = Assessment.report(id)
      assert {:ok, %{status: :report_not_written}} = Session.attach(id, fn _ -> true end)
      # Not a conversation any more: no answers, no finishing early.
      assert {:error, :not_waiting} = Assessment.answer(id, "More.")
      assert {:error, :not_running} = Assessment.finish_early(id)

      # The script is used up, so the next report call gets the default report.
      assert :ok = Assessment.retry_report(id)
      assert_event(id, {:report, %Report{}})
      report_request = agent |> LLMScript.requests() |> List.last()
      assert report_request.purpose == :report
      assert List.last(report_request.messages).content =~ "Only answer."
      assert {:error, :not_waiting} = Assessment.retry_report(id)
    end

    test "a report that is never asked for again is given up after its time to live" do
      script =
        [LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)] ++
          List.duplicate({:error, :rate_limited}, 4)

      {id, _} = start!(script, limits: %{report_ttl_ms: 50})
      assert_event(id, {:question, _})
      capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
      capture_log(fn -> assert_event(id, {:report_not_written, :rate_limited}) end)
      capture_log(fn -> assert_event(id, {:failed, :transient}) end)
      assert gone?(id)
    end

    test "trying the report again restarts the give-up time" do
      # Fails twice (three tries each), then the default report.
      script =
        [LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)] ++
          List.duplicate({:error, :transient}, 6)

      {id, _} = start!(script, limits: %{report_ttl_ms: 600})
      assert_event(id, {:question, _})
      capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
      capture_log(fn -> assert_event(id, {:report_not_written, :transient}) end)

      Process.sleep(400)
      capture_log(fn -> :ok = Assessment.retry_report(id) end)
      capture_log(fn -> assert_event(id, {:report_not_written, :transient}) end)

      # Past the first give-up time, but not the second: still waiting.
      Process.sleep(300)
      assert is_pid(Session.whereis(id))
      refute_event(id, {:failed, _})

      :ok = Assessment.retry_report(id)
      assert_event(id, {:report, %Report{}})
    end

    test "a fatal report failure still ends the session" do
      {id, _} =
        start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true), {:error, :fatal}])

      assert_event(id, {:question, _})
      capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
      capture_log(fn -> assert_event(id, {:failed, :fatal}) end)
      refute_event(id, {:report_not_written, _})
      assert gone?(id)
    end

    test "a model call whose task is killed is fatal" do
      {id, _} = start!([fn _ -> Process.exit(self(), :kill) end])
      capture_log(fn -> assert_event(id, {:failed, :fatal}) end)
      assert gone?(id)
    end

    test "an unusable turn is asked again once, then is fatal" do
      bad = {:ok, %{"question" => "", "kind" => "main", "covered_areas" => [], "close" => false}}

      {id, _} = start!([bad, LLMScript.turn("Q1")])
      capture_log(fn -> assert_event(id, {:question, %{text: "Q1"}}) end)

      {id, _} = start!([bad, bad])
      capture_log(fn -> assert_event(id, {:failed, :fatal}) end)
      assert gone?(id)
    end

    test "a report that fails validation twice is :report_invalid" do
      bad = {:ok, %{"summary" => "only this"}}
      {id, _} = start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true), bad, bad])
      assert_event(id, {:question, _})
      capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
      assert_event(id, {:closed, :covered})
      capture_log(fn -> assert_event(id, {:failed, :report_invalid}) end)
      assert gone?(id)
    end
  end

  describe "the reading list" do
    test "is read when the report is written, from a list or a function" do
      item = %{id: 5, title: "Guide", role_groups: [], areas: [:attitude], note: nil}

      for reading <- [[item], fn -> [item] end] do
        {id, _} =
          start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)], reading: reading)

        assert_event(id, {:question, _})
        :ok = Assessment.answer(id, "One.")
        assert_event(id, {:report, %Report{reading_picks: [%{id: 5}]}})
      end
    end

    test "a reading list that cannot be read fails the report, not silently" do
      {id, _} =
        start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)],
          reading: fn -> raise "database unavailable" end
        )

      assert_event(id, {:question, _})
      capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
      assert_event(id, {:closed, :covered})
      capture_log(fn -> assert_event(id, {:failed, :fatal}) end)
    end
  end

  describe "lifetime" do
    test "the session dies with its owner and leaves nothing behind" do
      test = self()

      owner =
        spawn(fn ->
          {client, _} = LLMScript.client([])
          {:ok, id} = Assessment.start(:people, llm: client, reading: [])
          send(test, {:id, id})
          Process.sleep(:infinity)
        end)

      assert_receive {:id, id}
      pid = Session.whereis(id)
      assert is_pid(pid)
      ref = Process.monitor(pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      assert gone?(id)
    end

    test "stop/1 ends the session" do
      {id, _} = start!([LLMScript.turn("Q1")])
      assert_event(id, {:question, _})
      assert :ok = Assessment.stop(id)
      assert gone?(id)
    end

    test "the report is discarded after its time to live" do
      {id, _} =
        start!([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)],
          limits: %{report_ttl_ms: 50}
        )

      assert_event(id, {:question, _})
      :ok = Assessment.answer(id, "One.")
      assert_event(id, {:report, _})
      assert gone?(id)
    end

    test "unexpected messages are ignored" do
      {id, _} = start!([LLMScript.turn("Q1")])
      assert_event(id, {:question, _})
      send(Session.whereis(id), :something_else)
      assert {:error, :not_ready} = Assessment.report(id)
    end
  end
end
