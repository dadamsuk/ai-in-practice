defmodule AiInPractice.LLM.OpenRouter do
  @moduledoc """
  The OpenRouter chat completions client (PRD §8.4, §12).

  Every request asks for zero data retention through OpenRouter's provider
  preferences, so it is routed only to endpoints that neither store nor
  train on the data:

      "provider": {"data_collection": "deny", "zdr": true, "require_parameters": true}

  `require_parameters` also keeps a request off any endpoint that would
  ignore its `response_format` (strict JSON schema output).

  The key comes from `OPENROUTER_API_KEY` at runtime (`config/runtime.exs`).
  Logs and telemetry carry the purpose, status and latency only; never a
  request or response body.
  """

  @behaviour AiInPractice.LLM

  require Logger

  @endpoint "https://openrouter.ai/api/v1/chat/completions"

  # 403s caused by a spent budget rather than a permissions problem
  # (https://openrouter.ai/docs/api-reference/errors).
  @budget_sources ~w(openrouter_guardrail_budget openrouter_workspace_budget openrouter_key_limit)

  @provider %{data_collection: "deny", zdr: true, require_parameters: true}

  @impl true
  def request(request, opts) do
    case api_key(opts) do
      nil ->
        Logger.error("llm #{request.purpose} not sent: OPENROUTER_API_KEY is not set")
        {:error, :fatal}

      key ->
        send_request(request, key, opts)
    end
  end

  defp send_request(request, key, opts) do
    started = System.monotonic_time(:millisecond)

    result =
      [
        url: @endpoint,
        auth: {:bearer, key},
        headers: [{"x-title", "AI in Practice"}],
        json: body(request, opts),
        receive_timeout: Keyword.get(opts, :receive_timeout, 90_000),
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:ai_in_practice, :openrouter_req_options, []))
      |> Req.post()

    latency = System.monotonic_time(:millisecond) - started
    {status, outcome} = interpret(result, request)

    Logger.info(
      "llm #{request.purpose} status=#{status} latency_ms=#{latency}" <>
        case outcome do
          {:error, class} -> " error=#{class}"
          _ -> ""
        end
    )

    :telemetry.execute(
      [:ai_in_practice, :llm, :request],
      %{duration_ms: latency},
      %{purpose: request.purpose, status: status, outcome: outcome_tag(outcome)}
    )

    outcome
  end

  defp outcome_tag({:ok, _}), do: :ok
  defp outcome_tag({:error, class}), do: class

  @doc false
  @spec body(AiInPractice.LLM.request(), keyword()) :: map()
  def body(request, opts \\ []) do
    %{
      model: Keyword.get_lazy(opts, :model, &AiInPractice.Version.model/0),
      messages: request.messages,
      max_tokens: Map.get(request, :max_tokens, 1024),
      provider: @provider
    }
    |> put_optional(:temperature, Map.get(request, :temperature))
    |> put_optional(:reasoning, Map.get(request, :reasoning))
    |> put_optional(:response_format, request |> Map.get(:schema) |> format())
  end

  defp format(nil), do: nil
  defp format(schema), do: AiInPractice.LLM.response_format(schema)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp api_key(opts) do
    Keyword.get_lazy(opts, :api_key, fn ->
      Application.get_env(:ai_in_practice, :openrouter_api_key)
    end)
  end

  @doc false
  # Returns {status for the log, outcome}. Never looks at more of an error
  # body than its code and limit source.
  def interpret({:ok, %Req.Response{status: 200, body: %{"error" => error}}}, _request) do
    {200, {:error, classify(error_code(error), error)}}
  end

  def interpret({:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = body}}, req) do
    {200, parse(choice, body, req)}
  end

  def interpret({:ok, %Req.Response{status: 200}}, _request), do: {200, {:error, :transient}}

  def interpret({:ok, %Req.Response{status: status, body: body}}, _request) do
    error = if is_map(body), do: Map.get(body, "error", %{}), else: %{}
    {status, {:error, classify(status, error)}}
  end

  def interpret({:error, %Req.TransportError{reason: reason}}, _request),
    do: {"transport:#{reason}", {:error, :transient}}

  def interpret({:error, _exception}, _request), do: {"error", {:error, :transient}}

  defp error_code(%{"code" => code}) when is_integer(code), do: code
  defp error_code(_), do: 502

  @doc false
  @spec classify(integer(), map()) :: AiInPractice.LLM.error_class()
  def classify(402, _error), do: :spend_refused

  def classify(403, error) do
    case error do
      %{"metadata" => %{"limit_source" => source}} when source in @budget_sources ->
        :spend_refused

      _ ->
        :fatal
    end
  end

  def classify(429, _error), do: :rate_limited
  def classify(408, _error), do: :transient
  def classify(status, _error) when status >= 500, do: :transient
  def classify(_status, _error), do: :fatal

  defp parse(%{"message" => %{"content" => content}}, body, request) when is_binary(content) do
    usage = usage(body["usage"])

    case Map.get(request, :schema) do
      nil ->
        {:ok, %{content: content, data: nil, usage: usage}}

      _schema ->
        case Jason.decode(strip_fences(content)) do
          {:ok, data} when is_map(data) -> {:ok, %{content: content, data: data, usage: usage}}
          _ -> {:error, :transient}
        end
    end
  end

  defp parse(_choice, _body, _request), do: {:error, :transient}

  # OpenRouter reports the cost of the call in US dollars; the evaluation
  # harness's budget guard counts it.
  defp usage(%{} = usage) do
    base = %{total_tokens: usage["total_tokens"] || 0}

    case usage["cost"] do
      cost when is_number(cost) -> Map.put(base, :cost, cost)
      _ -> base
    end
  end

  defp usage(_), do: %{total_tokens: 0}

  # Some models wrap JSON in a Markdown code fence even when asked not to.
  defp strip_fences(content) do
    content
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*|\s*```\z/, "")
  end
end
