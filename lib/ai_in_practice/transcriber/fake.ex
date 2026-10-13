defmodule AiInPractice.Transcriber.Fake do
  @moduledoc """
  A stand-in for the transcription engine, for tests and for walking the
  voice journey in development (`FAKE_TRANSCRIBER=1`, dev only).

  With no options it answers every recording with the same sentence and
  says it is ready. `:fail` (an error class) fails every recording,
  `:ready` (default `true`) is what `ready?/1` answers, and tests pass
  `responder: fn audio, format -> ... end` to script any reply.
  `modes/0` names the combinations `FAKE_TRANSCRIBER` selects.
  """

  @behaviour AiInPractice.Transcriber

  @text "Last month I used an AI assistant to draft the board pack summary, then checked every figure against the finance model before it went out."

  @modes %{
    "1" => [],
    "true" => [],
    "unavailable" => [fail: :unavailable],
    "no_speech" => [fail: :no_speech],
    "down" => [ready: false]
  }

  @doc """
  The `FAKE_TRANSCRIBER` values (dev only): `1` (every recording becomes
  the same sentence), `unavailable` and `no_speech` (every recording
  fails so), and `down` (voice is not offered).
  """
  @spec modes() :: %{String.t() => keyword()}
  def modes, do: @modes

  @doc "The sentence every recording becomes by default."
  def text, do: @text

  @impl true
  def transcribe(audio, format, opts) do
    cond do
      responder = opts[:responder] -> responder.(audio, format)
      class = opts[:fail] -> {:error, class}
      true -> {:ok, @text}
    end
  end

  @impl true
  def ready?(opts), do: Keyword.get(opts, :ready, true)
end
