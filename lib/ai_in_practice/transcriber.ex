defmodule AiInPractice.Transcriber do
  @moduledoc """
  The one door to speech-to-text, for spoken answers (PRD §7 step 3, §10
  Voice, v2).

  A client is a `{module, opts}` pair whose module implements this
  behaviour: `AiInPractice.Transcriber.Manuel` (David's transcription
  engine) in production and `AiInPractice.Transcriber.Fake` in tests and,
  behind the dev-only `FAKE_TRANSCRIBER` flag, in development. With no
  client configured (`config :ai_in_practice, :transcriber, nil`), voice is
  not offered and everyone types.

  Failures come back as one of three classes, which the UI acts on:

    * `:unavailable`: the service is down, busy or refused us. Try again
      later, or type.
    * `:unusable`: the recording itself could not be used (unknown format,
      undecodable, too long, too large).
    * `:no_speech`: the recording held no words.

  Privacy (PRD §10): the audio and the text are a person's answer. They
  are held only in the calling process, sent to the service and dropped.
  Nothing here, or in a client, logs or emits either. Logs carry the
  status, latency and error class only.
  """

  @type format :: String.t()
  @type error_class :: :unavailable | :unusable | :no_speech
  @type client :: {module(), keyword()}

  @doc """
  Transcribes one recording. `format` is the audio container's file
  extension (`"webm"`, `"ogg"`, `"m4a"`, ...).
  """
  @callback transcribe(audio :: binary(), format(), keyword()) ::
              {:ok, String.t()} | {:error, error_class()}

  @doc "Whether the service answers just now. Called before voice is offered."
  @callback ready?(keyword()) :: boolean()

  @doc "The configured client, or nil when voice is switched off."
  @spec client() :: client() | nil
  def client do
    case Application.get_env(:ai_in_practice, :transcriber) do
      nil -> nil
      {module, opts} -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc "Whether voice can be offered: a client is configured and it answers."
  @spec available?(client() | nil) :: boolean()
  def available?(client \\ client())
  def available?(nil), do: false
  def available?({module, opts}), do: module.ready?(opts)

  @doc """
  Transcribes `audio` with `client` (default: the configured one). Empty
  text is `{:error, :no_speech}`; the text is otherwise trimmed.
  """
  @spec transcribe(binary(), format(), client() | nil) ::
          {:ok, String.t()} | {:error, error_class()}
  def transcribe(audio, format, client \\ client())
  def transcribe(_audio, _format, nil), do: {:error, :unavailable}

  def transcribe(audio, format, {module, opts}) do
    case module.transcribe(audio, format, opts) do
      {:ok, text} when is_binary(text) ->
        case String.trim(text) do
          "" -> {:error, :no_speech}
          text -> {:ok, text}
        end

      {:error, class} ->
        {:error, class}
    end
  end

  @formats %{
    "audio/webm" => "webm",
    "video/webm" => "webm",
    "audio/ogg" => "ogg",
    "audio/mp4" => "m4a",
    "video/mp4" => "m4a",
    "audio/aac" => "aac",
    "audio/mpeg" => "mp3",
    "audio/wav" => "wav",
    "audio/x-wav" => "wav"
  }

  @doc """
  The file extension for a browser recording's MIME type (MediaRecorder
  gives `audio/webm;codecs=opus` in Chrome and Firefox, `audio/mp4` in
  Safari), or `:error` for anything else.
  """
  @spec format(String.t() | nil) :: {:ok, format()} | :error
  def format(mime) when is_binary(mime) do
    base = mime |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    Map.fetch(@formats, base)
  end

  def format(_mime), do: :error
end
