defmodule AiInPractice.Transcriber.Manuel do
  @moduledoc """
  The client for David's transcription engine (Manuel2's server API,
  `POST /v1/audio/transcriptions`, OpenAI style multipart).

  Every request:

    * names the local Parakeet model (`:model`, default `"parakeet"`)
      rather than `default`, so the audio can never be routed to the
      engine's cloud backend, and an explicit model never falls back;
    * sends `retain=false`, so the engine keeps no transcript after
      answering;
    * sends no `Idempotency-Key`, because the engine keeps a keyed result in
      memory for a day to replay it, and is not retried: the person records
      again or types;
    * sends `Prefer: wait=60`, so a busy engine refuses at once
      (`503 sync_wait_too_long`) rather than keeping the person waiting.

  The address and key come from `TRANSCRIPTION_SERVICE_URL` and
  `TRANSCRIPTION_SERVICE_KEY` at runtime (`config/runtime.exs`). Logs and
  telemetry carry the status and latency only; never the audio or the text.
  """

  @behaviour AiInPractice.Transcriber

  require Logger

  @impl true
  def transcribe(audio, format, opts) do
    case config(opts) do
      {:ok, base, key} -> send_request(audio, format, base, key, opts)
      :error -> {:error, :unavailable}
    end
  end

  @impl true
  def ready?(opts) do
    case config(opts) do
      {:ok, base, _key} ->
        case Req.get(req_options(base <> "/healthz", opts, 2_000)) do
          {:ok, %Req.Response{status: 200}} -> true
          _ -> false
        end

      :error ->
        false
    end
  end

  defp send_request(audio, format, base, key, opts) do
    started = System.monotonic_time(:millisecond)

    result =
      (base <> "/v1/audio/transcriptions")
      |> req_options(opts, Keyword.get(opts, :receive_timeout, 75_000))
      |> Keyword.merge(
        auth: {:bearer, key},
        headers: [{"prefer", "wait=60"}],
        form_multipart: form(audio, format, opts)
      )
      |> Req.post()

    latency = System.monotonic_time(:millisecond) - started
    {status, outcome} = interpret(result)

    Logger.info(
      "transcription status=#{status} latency_ms=#{latency}" <>
        case outcome do
          {:error, class} -> " error=#{class}"
          _ -> ""
        end
    )

    :telemetry.execute(
      [:ai_in_practice, :transcription, :request],
      %{duration_ms: latency, bytes: byte_size(audio)},
      %{status: status, outcome: outcome_tag(outcome)}
    )

    outcome
  end

  @doc false
  def form(audio, format, opts \\ []) do
    [
      file: {audio, filename: "answer.#{format}", content_type: "application/octet-stream"},
      model: Keyword.get(opts, :model, "parakeet"),
      language: "en",
      response_format: "json",
      retain: "false"
    ]
  end

  defp req_options(url, opts, timeout) do
    [url: url, receive_timeout: timeout, connect_options: [timeout: 5_000], retry: false]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Keyword.merge(Application.get_env(:ai_in_practice, :transcriber_req_options, []))
  end

  defp config(opts) do
    base = Keyword.get_lazy(opts, :url, fn -> env(:url) end)
    key = Keyword.get_lazy(opts, :api_key, fn -> env(:api_key) end)

    if present?(base) and present?(key),
      do: {:ok, String.trim_trailing(base, "/"), key},
      else: :error
  end

  defp env(name),
    do: :ai_in_practice |> Application.get_env(:transcription_service, []) |> Keyword.get(name)

  defp present?(value), do: is_binary(value) and value != ""

  defp outcome_tag({:ok, _}), do: :ok
  defp outcome_tag({:error, class}), do: class

  @doc false
  # Returns {status for the log, outcome}. Never looks at more of an error
  # body than its code.
  def interpret({:ok, %Req.Response{status: 200, body: %{"text" => text}}}) when is_binary(text),
    do: {200, {:ok, text}}

  def interpret({:ok, %Req.Response{status: 200}}), do: {200, {:error, :unavailable}}

  def interpret({:ok, %Req.Response{status: status, body: body}}) do
    {status, {:error, classify(status, error_code(body))}}
  end

  def interpret({:error, %Req.TransportError{reason: reason}}),
    do: {"transport:#{reason}", {:error, :unavailable}}

  def interpret({:error, _exception}), do: {"error", {:error, :unavailable}}

  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(_body), do: nil

  @doc false
  # The audio is the problem (spec §6: 413, 415, 422): recording again in
  # the same way will not help. Everything else is the service's.
  @spec classify(integer(), String.t() | nil) :: AiInPractice.Transcriber.error_class()
  def classify(_status, "idempotency_key_reused"), do: :unavailable
  def classify(status, _code) when status in [413, 415, 422], do: :unusable
  def classify(_status, _code), do: :unavailable
end
