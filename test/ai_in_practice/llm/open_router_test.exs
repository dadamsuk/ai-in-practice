defmodule AiInPractice.LLM.OpenRouterTest do
  # Not async: the log-capture tests raise the Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AiInPractice.LLM
  alias AiInPractice.LLM.OpenRouter

  @client {OpenRouter, []}
  @secret_prompt "PROMPT-MARKER the board paper on pricing"
  @secret_answer "ANSWER-MARKER our churn fell by a third"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{purpose: :turn, messages: [%{role: "user", content: @secret_prompt}], max_tokens: 50},
      overrides
    )
  end

  defp reply(conn, status, body) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp ok_body(content) do
    %{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
      "usage" => %{"total_tokens" => 321}
    }
  end

  defp decoded_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  describe "request body" do
    test "every request asks for zero data retention routing" do
      parent = self()

      Req.Test.expect(OpenRouter, 2, fn conn ->
        send(parent, {:body, decoded_body(conn)})
        reply(conn, 200, ok_body("hello"))
      end)

      assert {:ok, _} = LLM.complete(request(), @client)
      assert {:ok, _} = LLM.complete(request(%{purpose: :report}), @client)

      for _ <- 1..2 do
        assert_received {:body, body}

        assert body["provider"] == %{
                 "data_collection" => "deny",
                 "zdr" => true,
                 "require_parameters" => true
               }

        assert body["model"] == AiInPractice.Version.model()
        assert body["max_tokens"] == 50
      end
    end

    test "a schema becomes a strict json_schema response_format and the reply is parsed" do
      parent = self()
      schema = {"turn", %{type: "object"}}

      Req.Test.expect(OpenRouter, fn conn ->
        send(parent, {:body, decoded_body(conn)})
        reply(conn, 200, ok_body(~s({"question": "Q?"})))
      end)

      assert {:ok, %{data: %{"question" => "Q?"}, usage: %{total_tokens: 321}}} =
               LLM.complete(request(%{schema: schema, temperature: 0.2}), @client)

      assert_received {:body, body}

      assert body["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{
                 "name" => "turn",
                 "strict" => true,
                 "schema" => %{"type" => "object"}
               }
             }

      assert body["temperature"] == 0.2
    end

    test "a JSON reply wrapped in a code fence is still parsed" do
      Req.Test.expect(OpenRouter, fn conn ->
        reply(conn, 200, ok_body("```json\n{\"a\": 1}\n```"))
      end)

      assert {:ok, %{data: %{"a" => 1}}} = LLM.complete(request(%{schema: {"x", %{}}}), @client)
    end

    test "without a schema the content comes back as text" do
      Req.Test.expect(OpenRouter, fn conn -> reply(conn, 200, ok_body("plain")) end)
      assert {:ok, %{content: "plain", data: nil}} = LLM.complete(request(), @client)
    end

    test "sends the key as a bearer token" do
      parent = self()

      Req.Test.expect(OpenRouter, fn conn ->
        send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        reply(conn, 200, ok_body("x"))
      end)

      LLM.complete(request(), {OpenRouter, api_key: "k-123"})
      assert_received {:auth, ["Bearer k-123"]}
    end

    test "with no key it refuses without sending anything" do
      previous = Application.get_env(:ai_in_practice, :openrouter_api_key)
      Application.delete_env(:ai_in_practice, :openrouter_api_key)
      on_exit(fn -> Application.put_env(:ai_in_practice, :openrouter_api_key, previous) end)

      log = capture_log(fn -> assert {:error, :fatal} = LLM.complete(request(), @client) end)
      assert log =~ "OPENROUTER_API_KEY is not set"
    end
  end

  describe "error classes" do
    for {status, body, class} <- [
          {402, %{"error" => %{"code" => 402, "message" => "Insufficient credits"}},
           :spend_refused},
          {403,
           %{
             "error" => %{
               "code" => 403,
               "message" => "Key limit exceeded",
               "metadata" => %{"limit_source" => "openrouter_key_limit"}
             }
           }, :spend_refused},
          {403,
           %{
             "error" => %{
               "code" => 403,
               "metadata" => %{"limit_source" => "openrouter_workspace_budget"}
             }
           }, :spend_refused},
          {403, %{"error" => %{"code" => 403, "message" => "flagged by moderation"}}, :fatal},
          {429, %{"error" => %{"code" => 429}}, :rate_limited},
          {400, %{"error" => %{"code" => 400}}, :fatal},
          {401, %{"error" => %{"code" => 401}}, :fatal},
          {404, "not json", :fatal}
        ] do
      test "#{status} #{inspect(body) |> String.slice(0, 60)} is #{class} and is not retried" do
        Req.Test.expect(OpenRouter, 1, fn conn ->
          reply(conn, unquote(status), unquote(Macro.escape(body)))
        end)

        capture_log(fn -> assert {:error, unquote(class)} = LLM.complete(request(), @client) end)
      end
    end

    for status <- [408, 500, 502, 503, 504] do
      test "#{status} is transient and retried until the attempts run out" do
        Req.Test.expect(OpenRouter, 3, fn conn ->
          reply(conn, unquote(status), %{"error" => %{"code" => unquote(status)}})
        end)

        capture_log(fn -> assert {:error, :transient} = LLM.complete(request(), @client) end)
      end
    end

    test "a 200 carrying an error object is classified by its code" do
      Req.Test.expect(OpenRouter, 1, fn conn ->
        reply(conn, 200, %{"error" => %{"code" => 402}})
      end)

      capture_log(fn -> assert {:error, :spend_refused} = LLM.complete(request(), @client) end)

      Req.Test.expect(OpenRouter, 3, fn conn ->
        reply(conn, 200, %{"error" => %{"message" => "provider failed"}})
      end)

      capture_log(fn -> assert {:error, :transient} = LLM.complete(request(), @client) end)
    end

    test "a timeout is transient, and a retry that succeeds returns the reply" do
      Req.Test.expect(OpenRouter, 2, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      Req.Test.expect(OpenRouter, 1, fn conn -> reply(conn, 200, ok_body("third time")) end)

      capture_log(fn ->
        assert {:ok, %{content: "third time"}} = LLM.complete(request(), @client)
      end)
    end

    test "a reply with no usable content, or JSON that does not parse, is transient" do
      Req.Test.expect(OpenRouter, 3, fn conn -> reply(conn, 200, %{"choices" => []}) end)
      capture_log(fn -> assert {:error, :transient} = LLM.complete(request(), @client) end)

      Req.Test.expect(OpenRouter, 3, fn conn -> reply(conn, 200, ok_body("not json")) end)

      capture_log(fn ->
        assert {:error, :transient} = LLM.complete(request(%{schema: {"x", %{}}}), @client)
      end)

      Req.Test.expect(OpenRouter, 3, fn conn ->
        reply(conn, 200, %{"choices" => [%{"message" => %{"content" => nil}}]})
      end)

      capture_log(fn -> assert {:error, :transient} = LLM.complete(request(), @client) end)
    end
  end

  describe "privacy" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    @tag :privacy
    test "logs carry purpose, status and latency, never the prompt or the answer" do
      Req.Test.expect(OpenRouter, 1, fn conn -> reply(conn, 200, ok_body(@secret_answer)) end)

      Req.Test.expect(OpenRouter, 1, fn conn ->
        reply(conn, 500, %{"error" => %{"message" => @secret_answer}})
      end)

      Req.Test.expect(OpenRouter, 2, fn conn ->
        reply(conn, 402, %{"error" => %{"message" => @secret_answer}})
      end)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = LLM.complete(request(), @client)
          assert {:error, :spend_refused} = LLM.complete(request(), @client)
          assert {:error, :spend_refused} = LLM.complete(request(%{purpose: :report}), @client)
        end)

      assert log =~ "llm turn status=200 latency_ms="
      assert log =~ "llm turn status=500"
      assert log =~ "error=spend_refused"
      refute log =~ "MARKER"
      refute log =~ "pricing"
      refute log =~ "churn"
    end

    @tag :privacy
    test "telemetry carries purpose, status and outcome only" do
      parent = self()
      handler = "llm-telemetry-#{System.unique_integer()}"

      capture_log(fn ->
        :telemetry.attach(
          handler,
          [:ai_in_practice, :llm, :request],
          fn _event, measurements, metadata, _ ->
            send(parent, {:telemetry, measurements, metadata})
          end,
          nil
        )
      end)

      on_exit(fn -> :telemetry.detach(handler) end)
      Req.Test.expect(OpenRouter, 1, fn conn -> reply(conn, 200, ok_body(@secret_answer)) end)

      capture_log(fn -> LLM.complete(request(), @client) end)

      assert_received {:telemetry, %{duration_ms: ms}, metadata}
      assert is_integer(ms)
      assert metadata == %{purpose: :turn, status: 200, outcome: :ok}
    end
  end
end
