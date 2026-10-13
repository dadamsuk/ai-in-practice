defmodule AiInPractice.LLM do
  @moduledoc """
  The one door to a language model (PRD §8.4, §12).

  A client is a `{module, opts}` pair whose module implements this
  behaviour: `AiInPractice.LLM.OpenRouter` in production and
  `AiInPractice.LLM.Fake` in tests and, behind the dev-only `FAKE_LLM`
  flag, in development. `complete/2` adds the retry policy every client
  shares.

  Failures come back as one of four classes, which the session and the UI
  act on:

    * `:spend_refused`: OpenRouter refused on credit or a spending limit.
      Not retried; the UI says the service is temporarily unavailable.
    * `:rate_limited`: too many requests. Not retried.
    * `:transient`: 5xx, timeouts, transport errors, unusable output.
      Retried with backoff.
    * `:fatal`: anything else (bad request, bad key). Not retried.

  Privacy (PRD §10): requests and responses carry a person's answers.
  Nothing here, or in a client, logs or emits a body. Logs and telemetry
  carry the purpose, status, latency and error class only.
  """

  require Logger

  @type purpose :: :turn | :report
  @type message :: %{role: String.t(), content: String.t()}
  @type request :: %{
          required(:purpose) => purpose(),
          required(:messages) => [message()],
          optional(:schema) => {String.t(), map()} | nil,
          optional(:max_tokens) => pos_integer(),
          optional(:temperature) => number()
        }
  @type response :: %{
          content: String.t(),
          data: map() | nil,
          usage: %{total_tokens: non_neg_integer()}
        }
  @type error_class :: :spend_refused | :rate_limited | :transient | :fatal
  @type client :: {module(), keyword()}

  @doc """
  Sends one request. When the request has a `:schema`, the reply is
  structured JSON matching it, parsed into `data`.
  """
  @callback request(request(), keyword()) :: {:ok, response()} | {:error, error_class()}

  @doc "The configured client, from `config :ai_in_practice, :llm`."
  @spec client() :: client()
  def client do
    case Application.fetch_env!(:ai_in_practice, :llm) do
      {module, opts} -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc """
  Sends `request` with `client` (default: the configured one), retrying
  transient failures after each delay in the `:llm_backoff_ms` config
  (default `[500, 2000]`, so three attempts at most).
  """
  @spec complete(request(), client()) :: {:ok, response()} | {:error, error_class()}
  def complete(request, {module, opts} \\ client()) do
    attempt(request, module, opts, backoff())
  end

  defp attempt(request, module, opts, delays) do
    case module.request(request, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, :transient} when delays != [] ->
        [delay | rest] = delays
        Logger.warning("llm #{request.purpose} transient failure, retrying in #{delay} ms")
        Process.sleep(delay)
        attempt(request, module, opts, rest)

      {:error, class} ->
        Logger.warning("llm #{request.purpose} failed: #{class}")
        {:error, class}
    end
  end

  defp backoff, do: Application.get_env(:ai_in_practice, :llm_backoff_ms, [500, 2000])

  @doc """
  The OpenAI-style `response_format` for a `{name, schema}` pair, which
  OpenRouter passes to the model as strict structured output.
  """
  @spec response_format({String.t(), map()}) :: map()
  def response_format({name, schema}) do
    %{type: "json_schema", json_schema: %{name: name, strict: true, schema: schema}}
  end
end
