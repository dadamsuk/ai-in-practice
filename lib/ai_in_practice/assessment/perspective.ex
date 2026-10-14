defmodule AiInPractice.Assessment.Perspective do
  @moduledoc """
  Whom each report speaks to (#802). The person's own report is
  written to them, "you", from start to finish; the assessor report is
  written about them, "they" and "this person". No report mixes the two.

    * `:you` text is for the person's report. It must not talk about the
      person in the third person: "this person", "the candidate", or a
      sentence that opens with "They" or "Their".
    * `:they` text is for the assessor report. It must not speak to the
      person as "you".

  Words inside quotation marks are the person's own and are skipped.
  `AiInPractice.Assessment.Report` rejects a draft that breaks this, and
  the evaluation gate counts the same slips.
  """

  @type t :: :you | :they

  @second_person ~r/\b(you|your|yours|yourself|yourselves)\b/iu
  # Not "the person": "ask the person who owns the process" is fine.
  @about_the_person ~r/\b(this person|this candidate|the candidate)\b/iu
  @they_opening ~r/(?:\A|[.!?:;]\s+|\n\s*)(?:They|Their|Them|Themselves)\b/u
  @quoted ~r/"[^"]*"|“[^”]*”/u

  @doc "Whether `text` keeps to `perspective`."
  @spec keeps?(String.t() | nil, t()) :: boolean()
  def keeps?(text, perspective) when is_binary(text) do
    text = String.replace(text, @quoted, "")

    case perspective do
      :they ->
        not Regex.match?(@second_person, text)

      :you ->
        not (Regex.match?(@about_the_person, text) or Regex.match?(@they_opening, text))
    end
  end

  def keeps?(_text, _perspective), do: true
end
