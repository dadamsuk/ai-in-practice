defmodule AiInPracticeWeb.AssessmentVoiceTest do
  # Spoken answers (PRD §7 step 2–3, §10 Voice). Not async: each test sets
  # the model and transcriber clients globally.
  use AiInPracticeWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import AiInPractice.LinksFixtures

  alias AiInPractice.{GlobalLog, LLMScript, Repo}
  alias AiInPractice.Links.AssessmentLink
  alias AiInPractice.Transcriber.Fake

  @audio "AUDIO-MARKER" <> :binary.copy(<<1, 2, 3, 250>>, 64)

  setup do
    llm = Application.get_env(:ai_in_practice, :llm)
    transcriber = Application.get_env(:ai_in_practice, :transcriber)

    on_exit(fn ->
      Application.put_env(:ai_in_practice, :llm, llm)
      Application.put_env(:ai_in_practice, :transcriber, transcriber)
    end)

    {recruiter, _} = recruiter_link_fixture()
    {link, token} = candidate_link_fixture(recruiter)
    %{link: link, token: token}
  end

  defp use_transcriber(opts), do: Application.put_env(:ai_in_practice, :transcriber, {Fake, opts})

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

  defp open(conn, token) do
    {:ok, view, _html} = live(conn, ~p"/a/#{token}")
    view
  end

  defp begin_voice(conn, token) do
    view = conn |> open(token) |> await("#begin-voice")
    view |> form("#begin-form") |> put_submitter("#begin-voice") |> render_submit()
    await(view, "#record")
  end

  defp record(view) do
    view |> element("#voice") |> render_hook("recording", %{})
    view |> element("#voice") |> render_hook("recorded", %{})
    view
  end

  defp upload(view, content \\ @audio, type \\ "audio/webm;codecs=opus") do
    input =
      file_input(view, "#voice-form", :audio, [%{name: "answer", content: content, type: type}])

    render_upload(input, "answer")
    view
  end

  defp link_mode(link), do: Repo.get!(AssessmentLink, link.id).mode

  describe "the start screen" do
    test "offers voice once the transcriber answers, and says how recordings are handled", %{
      conn: conn,
      token: token
    } do
      view = conn |> open(token) |> await("#begin-voice")

      assert has_element?(view, "#begin.button-primary", "Begin, typing my answers")
      assert has_element?(view, "#begin-voice", "Begin, speaking my answers")
      assert has_element?(view, "#voice-offered", "speak them and correct the text")

      handling = view |> element("#voice-handling") |> render()
      assert handling =~ "deleted at once"
      assert handling =~ "never stored"
      assert handling =~ "correct it before you send it"
      assert handling =~ "only ever shown on screen"
      assert handling =~ "transcription slips never count against you"
    end

    test "without a transcriber, voice is not offered", %{conn: conn, token: token} do
      Application.put_env(:ai_in_practice, :transcriber, nil)
      view = open(conn, token)
      # Give the check its chance to answer.
      Process.sleep(50)
      html = render(view)

      refute has_element?(view, "#begin-voice")
      refute has_element?(view, "#voice-handling")
      assert has_element?(view, "#begin", "Begin the conversation")
      assert html =~ "Type your answers."
    end

    test "when the transcriber does not answer, voice is not offered", %{
      conn: conn,
      token: token
    } do
      use_transcriber(ready: false)
      view = open(conn, token)
      Process.sleep(50)
      refute has_element?(view, "#begin-voice")
    end

    test "a forged voice choice on a page that did not offer it begins with typing", %{
      conn: conn,
      link: link,
      token: token
    } do
      Application.put_env(:ai_in_practice, :transcriber, nil)
      view = open(conn, token)
      render_submit(view, "begin", %{"mode" => "voice"})
      await(view, "#question")

      refute has_element?(view, "#voice")
      assert link_mode(link) == :text
    end

    test "typing is the default choice when voice is offered", %{
      conn: conn,
      link: link,
      token: token
    } do
      view = conn |> open(token) |> await("#begin-voice")
      view |> form("#begin-form") |> put_submitter("#begin") |> render_submit()
      await(view, "#question")

      refute has_element?(view, "#voice")
      assert has_element?(view, "#answer-help", "Type, or use your computer")
      assert link_mode(link) == :text
    end
  end

  describe "a spoken answer" do
    test "is recorded, turned into text for the box, corrected, then sent", %{
      conn: conn,
      link: link,
      token: token
    } do
      view = begin_voice(conn, token)
      assert link_mode(link) == :voice
      assert has_element?(view, "#answer-help", "correct anything misheard")
      # The question is only ever on screen: no audio anywhere on the page.
      refute render(view) =~ "<audio"

      view |> element("#voice") |> render_hook("recording", %{})
      assert has_element?(view, "#recording.recording", "Recording.")

      # The design rule: the accent at most twice on a screen (the send
      # button and the recording indicator).
      html = render(view)
      accents = length(Regex.scan(~r/button-primary|class="recording"/, html))
      assert accents == 2
      assert has_element?(view, "#stop-recording[data-voice='stop']")
      refute has_element?(view, "#record")

      view |> element("#voice") |> render_hook("recorded", %{})
      assert has_element?(view, "#transcribing", "Turning your recording into text.")
      assert has_element?(view, "#send[disabled]")

      upload(view)
      assert_push_event(view, "transcribed", %{text: text})
      assert text == Fake.text()

      await(view, "#record")
      refute has_element?(view, "#send[disabled]")
      refute has_element?(view, "#voice-error")

      # The person's corrected text is the answer; the transcription is not.
      corrected = String.replace(text, "board pack", "investor update")
      view |> form("#answer-form", %{answer: corrected}) |> render_submit()
      await(view, "#question[data-number='2']")
      await(view, "#record")
    end

    test "a draft typed before recording survives the controls changing", %{
      conn: conn,
      token: token
    } do
      view = begin_voice(conn, token)
      view |> form("#answer-form", %{answer: "Typed first,"}) |> render_change()
      record(view)

      assert view |> element("#answer-form textarea") |> render() =~ "Typed first,"

      # A draft is capped like an answer.
      view |> form("#answer-form", %{answer: String.duplicate("a", 9_000)}) |> render_change()
      text = view |> element("#answer-form textarea") |> render()
      assert text =~ String.duplicate("a", 8_000)
      refute text =~ String.duplicate("a", 8_001)
    end

    test "the reports say the answers were spoken", %{conn: conn, token: token} do
      {client, _} =
        LLMScript.client([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])

      Application.put_env(:ai_in_practice, :llm, client)
      view = begin_voice(conn, token)
      view |> record() |> upload()
      assert_push_event(view, "transcribed", %{text: _})
      view |> form("#answer-form", %{answer: "I checked every figure myself."}) |> render_submit()
      await(view, "#candidate-report")

      for report <- ~w(#candidate-report #assessor-report) do
        assert has_element?(view, "#{report} dt", "answers")
        assert has_element?(view, "#{report} dd", "spoken")
      end
    end

    test "the recording reaches the transcriber whole, with its format", %{
      conn: conn,
      token: token
    } do
      test = self()

      use_transcriber(
        responder: fn audio, format ->
          send(test, {:transcribed, audio, format})
          {:ok, "Heard."}
        end
      )

      view = begin_voice(conn, token)
      view |> record() |> upload(@audio, "audio/mp4")

      assert_receive {:transcribed, @audio, "m4a"}, 1000
      assert_push_event(view, "transcribed", %{text: "Heard."})
    end

    test "never touches disk: no upload temp file is written", %{conn: conn, token: token} do
      tmp = Path.join(System.tmp_dir!(), "plug-*/live_view_upload-*")
      before = Path.wildcard(tmp)

      view = begin_voice(conn, token)
      view |> record() |> upload()
      assert_push_event(view, "transcribed", %{text: _})

      assert Path.wildcard(tmp) -- before == []
    end
  end

  describe "when voice fails, typing is always there" do
    for {mode, class, message} <- [
          {:no_speech, :no_speech, "No words were heard in that recording."},
          {:unavailable, :unavailable, "could not be turned into text just now"},
          {:unusable, :unusable, "That recording could not be used."}
        ] do
      test "#{mode}: says so, offers recording again, and keeps the answer box", %{
        conn: conn,
        token: token
      } do
        use_transcriber(fail: unquote(class))
        view = begin_voice(conn, token)
        view |> record() |> upload()

        await(view, "#voice-error")
        assert has_element?(view, "#voice-error[role='alert']", unquote(message))
        assert has_element?(view, "#voice-error", "type your answer")
        assert has_element?(view, "#record")
        refute has_element?(view, "#send[disabled]")

        view |> form("#answer-form", %{answer: "Typed instead."}) |> render_submit()
        await(view, "#question[data-number='2']")
        refute has_element?(view, "#voice-error")
      end
    end

    test "a transcriber that crashes is treated as unavailable", %{conn: conn, token: token} do
      use_transcriber(responder: fn _audio, _format -> raise "engine exploded" end)
      view = begin_voice(conn, token)
      view |> record() |> upload()

      await(view, "#voice-error")
      assert has_element?(view, "#voice-error", "could not be turned into text just now")
    end

    test "a microphone that is refused or missing says so", %{conn: conn, token: token} do
      view = begin_voice(conn, token)

      for reason <- ~w(denied unsupported) do
        view |> element("#voice") |> render_hook("recording_failed", %{"reason" => reason})
        assert has_element?(view, "#voice-error", "The microphone could not be used.")
        assert has_element?(view, "#record")
      end
    end

    test "an empty recording is no speech", %{conn: conn, token: token} do
      view = begin_voice(conn, token)
      view |> element("#voice") |> render_hook("recording", %{})
      view |> element("#voice") |> render_hook("recording_failed", %{"reason" => "empty"})
      assert has_element?(view, "#voice-error", "No words were heard")
    end

    test "a recording in a format the transcriber cannot take is not sent", %{
      conn: conn,
      token: token
    } do
      test = self()

      use_transcriber(
        responder: fn _, _ ->
          send(test, :sent)
          {:ok, "x"}
        end
      )

      view = begin_voice(conn, token)
      view |> record() |> upload("plain text", "text/plain")

      assert has_element?(view, "#voice-error", "That recording could not be used.")
      refute_received :sent
    end

    test "a recording over the size limit is refused", %{conn: conn, token: token} do
      view = begin_voice(conn, token)
      record(view)

      input =
        file_input(view, "#voice-form", :audio, [
          %{name: "answer", content: :binary.copy("a", 16_000_001), type: "audio/webm"}
        ])

      assert {:error, [[_ref, :too_large]]} = render_upload(input, "answer")
      render_change(view, "voice_upload", %{})
      assert has_element?(view, "#voice-error", "That recording could not be used.")
    end

    test "text that arrives after the question has moved on is dropped", %{
      conn: conn,
      token: token
    } do
      test = self()

      use_transcriber(
        responder: fn _audio, _format ->
          send(test, {:transcribing, self()})

          receive do
            :go -> {:ok, "Too late."}
          end
        end
      )

      view = begin_voice(conn, token)
      view |> form("#answer-form", %{answer: "A typed first answer."}) |> render_submit()
      await(view, "#question[data-number='2']")
      await(view, "#record")
      view |> record() |> upload()
      assert_receive {:transcribing, task}, 1000

      view |> element("#finish") |> render_click()
      send(task, :go)
      await(view, "#candidate-report")
      refute_push_event(view, "transcribed", %{text: "Too late."}, 200)
    end

    test "recording events outside a question change nothing", %{conn: conn, token: token} do
      view = conn |> open(token) |> await("#begin-voice")
      render_hook(view, "recording", %{})
      render_hook(view, "recorded", %{})
      render_change(view, "voice_upload", %{})
      assert has_element?(view, "#begin-voice")
      refute has_element?(view, "#recording")
    end
  end

  describe "privacy" do
    @describetag :privacy

    # GlobalLog captures every process's logs itself.
    @tag capture_log: false
    test "a spoken answer leaves no audio or text in any log", %{conn: conn, token: token} do
      use_transcriber(responder: fn _, _ -> {:ok, "TRANSCRIPT-MARKER we halved the close"} end)

      log =
        GlobalLog.capture(:debug, fn ->
          view = begin_voice(conn, token)
          view |> record() |> upload()
          assert_push_event(view, "transcribed", %{text: text})

          view |> form("#answer-form", %{answer: text <> " EDIT-MARKER"}) |> render_submit()
          await(view, "#question[data-number='2']")
        end)

      assert log =~ "HANDLE EVENT"
      refute log =~ "AUDIO-MARKER"
      refute log =~ "TRANSCRIPT-MARKER"
      refute log =~ "halved the close"
      refute log =~ "EDIT-MARKER"
      refute log =~ token
    end

    @tag capture_log: false
    test "a transcriber that crashes logs no audio", %{conn: conn, token: token} do
      use_transcriber(responder: fn _audio, _format -> raise "engine exploded" end)

      log =
        GlobalLog.capture(:debug, fn ->
          view = begin_voice(conn, token)
          view |> record() |> upload()
          await(view, "#voice-error")
        end)

      refute log =~ "AUDIO-MARKER"
      refute log =~ token
    end
  end
end
