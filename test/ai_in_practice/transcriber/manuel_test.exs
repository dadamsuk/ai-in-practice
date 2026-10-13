defmodule AiInPractice.Transcriber.ManuelTest do
  # Not async: the log-capture tests raise the Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.Transcriber
  alias AiInPractice.Transcriber.Manuel

  @opts [url: "http://engine.test:8765/", api_key: "mk-test-key", model: "parakeet"]
  @client {Manuel, @opts}
  @audio "AUDIO-MARKER" <> :binary.copy(<<0, 255, 17>>, 50)
  @spoken "TRANSCRIPT-MARKER we cut invoice errors by a third"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp reply(conn, status, body), do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp error(code), do: %{"error" => %{"code" => code, "message" => "m", "type" => "t"}}

  defp raw_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {body, conn}
  end

  defp field(body, name) do
    case Regex.run(~r/name="#{name}"\r\n\r\n(.*?)\r\n--/s, body) do
      [_, value] -> value
      nil -> nil
    end
  end

  describe "the request" do
    test "posts the audio as multipart to the engine, with the key, local model and retain=false" do
      parent = self()

      Req.Test.expect(Manuel, fn conn ->
        {body, conn} = raw_body(conn)
        send(parent, {:request, conn, body})
        reply(conn, 200, %{"text" => @spoken, "id" => "trn_1", "model" => "parakeet"})
      end)

      assert Transcriber.transcribe(@audio, "webm", @client) == {:ok, @spoken}
      assert_received {:request, conn, body}

      assert conn.method == "POST"
      assert conn.host == "engine.test"
      assert conn.port == 8765
      assert conn.request_path == "/v1/audio/transcriptions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer mk-test-key"]
      assert Plug.Conn.get_req_header(conn, "prefer") == ["wait=60"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
      assert [type] = Plug.Conn.get_req_header(conn, "content-type")
      assert type =~ "multipart/form-data"

      assert body =~ ~s(name="file"; filename="answer.webm")
      assert body =~ @audio
      assert field(body, "model") == "parakeet"
      assert field(body, "language") == "en"
      assert field(body, "response_format") == "json"
      assert field(body, "retain") == "false"
    end

    test "the file name carries the recording's format" do
      Req.Test.expect(Manuel, fn conn ->
        {body, conn} = raw_body(conn)
        assert body =~ ~s(filename="answer.m4a")
        reply(conn, 200, %{"text" => "fine"})
      end)

      assert Transcriber.transcribe(@audio, "m4a", @client) == {:ok, "fine"}
    end

    test "without an address or a key, nothing is sent" do
      assert Transcriber.transcribe(@audio, "webm", {Manuel, url: nil, api_key: "k"}) ==
               {:error, :unavailable}

      assert Transcriber.transcribe(@audio, "webm", {Manuel, url: "http://x", api_key: ""}) ==
               {:error, :unavailable}
    end

    test "reads the address and key from the application config by default" do
      saved = Application.get_env(:ai_in_practice, :transcription_service)
      on_exit(fn -> Application.put_env(:ai_in_practice, :transcription_service, saved) end)

      Application.put_env(:ai_in_practice, :transcription_service,
        url: "http://configured.test:1234",
        api_key: "mk-configured"
      )

      Req.Test.expect(Manuel, fn conn ->
        assert conn.host == "configured.test"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer mk-configured"]
        reply(conn, 200, %{"text" => "configured"})
      end)

      assert Transcriber.transcribe(@audio, "webm", {Manuel, []}) == {:ok, "configured"}
    end
  end

  describe "the answer" do
    test "silence (empty text) is no speech" do
      Req.Test.expect(Manuel, &reply(&1, 200, %{"text" => "  "}))
      assert Transcriber.transcribe(@audio, "webm", @client) == {:error, :no_speech}
    end

    test "a 200 without text is unavailable" do
      Req.Test.expect(Manuel, &reply(&1, 200, %{"id" => "trn_1"}))
      assert Transcriber.transcribe(@audio, "webm", @client) == {:error, :unavailable}
    end

    for {status, code} <- [
          {413, "upload_too_large"},
          {415, "unsupported_audio_format"},
          {422, "audio_undecodable"},
          {422, "audio_too_long"}
        ] do
      test "#{status} #{code} means the recording cannot be used" do
        Req.Test.expect(Manuel, &reply(&1, unquote(status), error(unquote(code))))
        assert Transcriber.transcribe(@audio, "webm", @client) == {:error, :unusable}
      end
    end

    for {status, code} <- [
          {401, "invalid_api_key"},
          {403, "user_not_allowed"},
          {400, "unsupported_parameter"},
          {429, "queue_full"},
          {503, "model_loading"},
          {503, "sync_wait_too_long"},
          {504, "sync_timeout"},
          {500, nil}
        ] do
      test "#{status} #{code} means the service is unavailable, and is not retried" do
        Req.Test.expect(Manuel, 1, &reply(&1, unquote(status), error(unquote(code))))
        assert Transcriber.transcribe(@audio, "webm", @client) == {:error, :unavailable}
      end
    end

    test "a transport error is unavailable" do
      Req.Test.expect(Manuel, &Req.Test.transport_error(&1, :econnrefused))
      assert Transcriber.transcribe(@audio, "webm", @client) == {:error, :unavailable}
    end

    test "a non-JSON error body is unavailable" do
      Req.Test.expect(Manuel, fn conn ->
        conn |> Plug.Conn.put_status(502) |> Plug.Conn.send_resp(502, "bad gateway")
      end)

      assert Transcriber.transcribe(@audio, "webm", @client) == {:error, :unavailable}
    end
  end

  describe "ready?/1" do
    test "is true when /healthz answers 200, without a key" do
      Req.Test.expect(Manuel, fn conn ->
        assert conn.request_path == "/healthz"
        assert conn.method == "GET"
        reply(conn, 200, %{"status" => "ok"})
      end)

      assert Transcriber.available?(@client)
    end

    test "is false when the engine does not answer or answers badly" do
      Req.Test.expect(Manuel, &Req.Test.transport_error(&1, :timeout))
      refute Transcriber.available?(@client)

      Req.Test.expect(Manuel, &reply(&1, 503, %{}))
      refute Transcriber.available?(@client)
    end

    test "is false without an address or key, without calling" do
      refute Transcriber.available?({Manuel, url: "", api_key: "k"})
    end
  end

  describe "privacy" do
    @describetag :privacy

    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "logs the status and latency, never the audio, the text or the key" do
      Req.Test.expect(Manuel, &reply(&1, 200, %{"text" => @spoken}))

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = Transcriber.transcribe(@audio, "webm", @client)
        end)

      assert log =~ "transcription status=200 latency_ms="
      refute log =~ "TRANSCRIPT-MARKER"
      refute log =~ "AUDIO-MARKER"
      refute log =~ "mk-test-key"
    end

    test "a failure logs its class, never the audio or the key" do
      Req.Test.expect(Manuel, &reply(&1, 422, error("audio_undecodable")))

      log =
        capture_log([level: :debug], fn ->
          assert {:error, :unusable} = Transcriber.transcribe(@audio, "webm", @client)
        end)

      assert log =~ "transcription status=422"
      assert log =~ "error=unusable"
      refute log =~ "AUDIO-MARKER"
      refute log =~ "mk-test-key"
    end

    test "telemetry carries the status, size and duration only" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:ai_in_practice, :transcription, :request]
        ])

      Req.Test.expect(Manuel, &reply(&1, 200, %{"text" => @spoken}))

      capture_log(fn -> assert {:ok, _} = Transcriber.transcribe(@audio, "webm", @client) end)

      assert_received {[:ai_in_practice, :transcription, :request], ^ref, measurements, metadata}
      assert measurements.bytes == byte_size(@audio)
      assert is_integer(measurements.duration_ms)
      assert metadata == %{status: 200, outcome: :ok}
    end
  end
end
