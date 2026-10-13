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
           covered: 0
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

    test "a failure mid-conversation ends the session" do
      {id, _} = start!([LLMScript.turn("Q1"), {:error, :rate_limited}])
      assert_event(id, {:question, _})
      capture_log(fn -> :ok = Assessment.answer(id, "One.") end)
      assert_event(id, {:failed, :rate_limited})
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
        assert_event(id, {:report, %Report{reading_picks: [5]}})
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
