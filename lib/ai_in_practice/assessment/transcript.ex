defmodule AiInPractice.Assessment.Transcript do
  @moduledoc """
  The questions asked and the answers given in one session, held only in
  the memory of the session's process (PRD §10).

  `inspect/1` shows only how many turns there are, so a transcript that
  ends up in an error message, a crash report or a `:sys.get_state` dump
  shows no words.
  """

  defstruct turns: [], unsent: nil

  @type kind :: :main | :follow_up
  @type turn :: %{question: String.t(), kind: kind(), answer: String.t() | nil}
  @type t :: %__MODULE__{turns: [turn()], unsent: String.t() | nil}

  @tags ~w(transcript question answer state reading)

  @doc "Adds a question, not yet answered."
  @spec ask(t(), String.t(), kind()) :: t()
  def ask(%__MODULE__{turns: turns} = transcript, question, kind) do
    %{transcript | turns: turns ++ [%{question: question, kind: kind, answer: nil}]}
  end

  @doc "Records the answer to the last question."
  @spec answer(t(), String.t()) :: t()
  def answer(%__MODULE__{turns: turns} = transcript, answer) do
    {last, rest} = List.pop_at(turns, -1)
    %{transcript | turns: rest ++ [%{last | answer: answer}], unsent: nil}
  end

  @doc """
  Takes the answer to the last question back out, so the question can be
  answered again (its turn could not be sent). Returns the answer and the
  transcript, which holds it as `unsent/1` until the next `answer/2`, or
  `:error` when the last question has no answer.
  """
  @spec unanswer(t()) :: {:ok, String.t(), t()} | :error
  def unanswer(%__MODULE__{turns: turns} = transcript) do
    case List.pop_at(turns, -1) do
      {%{answer: answer} = last, rest} when is_binary(answer) ->
        {:ok, answer, %{transcript | turns: rest ++ [%{last | answer: nil}], unsent: answer}}

      _ ->
        :error
    end
  end

  @doc "The answer taken back by `unanswer/1` and not yet sent again, or nil."
  @spec unsent(t()) :: String.t() | nil
  def unsent(%__MODULE__{unsent: unsent}), do: unsent

  @doc "The turns that have an answer, dropping a last unanswered question."
  @spec answered(t()) :: t()
  def answered(%__MODULE__{turns: turns}),
    do: %__MODULE__{turns: Enum.reject(turns, &is_nil(&1.answer))}

  @doc "The answers, in order."
  @spec answers(t()) :: [String.t()]
  def answers(%__MODULE__{turns: turns}), do: for(%{answer: a} <- turns, a, do: a)

  @doc "The number of turns."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{turns: turns}), do: length(turns)

  @doc """
  The transcript as delimited text for a prompt. Answers are wrapped in
  `<answer>` tags and any tag-like text inside them that could close the
  delimiters is neutralised, so an answer cannot pose as instructions.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{turns: turns}) do
    body =
      turns
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {turn, n} ->
        question =
          ~s(<question n="#{n}" kind="#{turn.kind}">#{neutralise(turn.question)}</question>)

        case turn.answer do
          nil -> question
          answer -> question <> "\n<answer>\n" <> neutralise(answer) <> "\n</answer>"
        end
      end)

    "<transcript>\n" <> body <> "\n</transcript>"
  end

  @doc false
  def neutralise(text) do
    String.replace(text, ~r{<(/?)(#{Enum.join(@tags, "|")})\b}i, "‹\\1\\2")
  end

  defimpl Inspect do
    def inspect(%{turns: turns}, _opts), do: "#Transcript<#{length(turns)} turns, redacted>"
  end
end
