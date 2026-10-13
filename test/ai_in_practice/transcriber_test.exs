defmodule AiInPractice.TranscriberTest do
  use ExUnit.Case, async: false

  alias AiInPractice.Transcriber
  alias AiInPractice.Transcriber.Fake

  describe "client/0" do
    setup do
      saved = Application.get_env(:ai_in_practice, :transcriber)
      on_exit(fn -> Application.put_env(:ai_in_practice, :transcriber, saved) end)
    end

    test "is the configured pair, a bare module with no options, or nil" do
      Application.put_env(:ai_in_practice, :transcriber, {Fake, fail: :unavailable})
      assert Transcriber.client() == {Fake, fail: :unavailable}

      Application.put_env(:ai_in_practice, :transcriber, Fake)
      assert Transcriber.client() == {Fake, []}

      Application.put_env(:ai_in_practice, :transcriber, nil)
      assert Transcriber.client() == nil
    end

    test "with none configured, voice is not available and nothing transcribes" do
      Application.put_env(:ai_in_practice, :transcriber, nil)
      refute Transcriber.available?()
      assert Transcriber.transcribe("audio", "webm") == {:error, :unavailable}
    end
  end

  describe "transcribe/3" do
    test "trims the text" do
      client = {Fake, responder: fn _audio, _format -> {:ok, "  we shipped it \n"} end}
      assert Transcriber.transcribe("audio", "webm", client) == {:ok, "we shipped it"}
    end

    test "passes the audio and format to the client" do
      test = self()

      client =
        {Fake,
         responder: fn audio, format ->
           send(test, {audio, format})
           {:ok, "x"}
         end}

      assert {:ok, "x"} = Transcriber.transcribe("the bytes", "ogg", client)
      assert_received {"the bytes", "ogg"}
    end

    test "empty text is no speech, and errors come back as they are" do
      assert Transcriber.transcribe("a", "webm", {Fake, responder: fn _, _ -> {:ok, ""} end}) ==
               {:error, :no_speech}

      assert Transcriber.transcribe("a", "webm", {Fake, fail: :unusable}) == {:error, :unusable}
    end
  end

  describe "format/1" do
    test "maps the browser recording types to file extensions" do
      assert Transcriber.format("audio/webm;codecs=opus") == {:ok, "webm"}
      assert Transcriber.format("audio/webm") == {:ok, "webm"}
      assert Transcriber.format("audio/ogg; codecs=opus") == {:ok, "ogg"}
      assert Transcriber.format("audio/mp4") == {:ok, "m4a"}
      assert Transcriber.format("AUDIO/MP4;codecs=mp4a.40.2") == {:ok, "m4a"}
      assert Transcriber.format("audio/wav") == {:ok, "wav"}
    end

    test "refuses anything else" do
      assert Transcriber.format("text/plain") == :error
      assert Transcriber.format("") == :error
      assert Transcriber.format(nil) == :error
    end
  end

  describe "the fake" do
    test "answers with a fixed sentence and is ready by default" do
      assert Transcriber.transcribe("a", "webm", {Fake, []}) == {:ok, Fake.text()}
      assert Transcriber.available?({Fake, []})
      refute Transcriber.available?({Fake, ready: false})
    end

    test "every FAKE_TRANSCRIBER mode is a valid set of options" do
      for {_name, opts} <- Fake.modes() do
        assert match?({:ok, _}, Transcriber.transcribe("a", "webm", {Fake, opts})) or
                 match?({:error, _}, Transcriber.transcribe("a", "webm", {Fake, opts}))
      end

      assert Fake.modes()["down"] == [ready: false]
    end
  end
end
