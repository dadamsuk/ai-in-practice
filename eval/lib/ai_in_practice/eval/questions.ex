defmodule AiInPractice.Eval.Questions do
  @moduledoc """
  Rough, automatic measures of question quality (rubric "Conversation
  design"; #714), from a run's transcript:

    * **follow-ups** and **consecutive follow-ups** (rubric principle 4:
      one follow-up, then move on; the engine enforces it, so any
      consecutive pair is a bug)
    * **grounded**: the share of questions after the first that reuse at
      least two distinctive words (five letters or more, not common
      question words) from the person's earlier answers, a sign the
      question builds on what they said
    * **near-script**: questions whose word overlap with one of the
      rubric's guidance questions is 0.5 or more, a sign of reading the
      script rather than writing its own

    * **level leaks**: questions that name a level or a score, by the same
      check the report text must pass (`AiInPractice.Assessment.Report.leak?/1`);
      nothing about levels may be revealed mid-session (#716)

  These are signals for a person to follow up in the transcripts, not
  verdicts.
  """

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Rubric

  @common ~w(about after again agent always answer answers anything around asked based
    before being between brief could describe described doing during earlier either every
    example examples first from going happened mention mentioned might other people
    really recent recently right said share should since something specific still taken
    their there these thing things think thinking those through today using wanted which
    while whose would years youve youre yourself)

  @guidance Rubric.sections()
            |> Enum.flat_map(fn {_title, body} ->
              case Regex.run(~r/\*\*Guidance questions[^\n]*\n((?:- .*\n?)+)/, body) do
                [_, list] -> list |> String.split("\n", trim: true)
                nil -> []
              end
            end)
            |> Enum.map(&String.replace(&1, ~r/^- (\*\([^)]*\)\* )?/, ""))

  @doc "The rubric's guidance questions, as the model sees them."
  @spec guidance() :: [String.t()]
  def guidance, do: @guidance

  @doc "The measures for one run's transcript."
  @spec measure([%{question: String.t(), kind: atom(), answer: String.t() | nil}]) :: map()
  def measure(transcript) do
    kinds = Enum.map(transcript, & &1.kind)

    %{
      questions: length(transcript),
      follow_ups: Enum.count(kinds, &(&1 == :follow_up)),
      consecutive_follow_ups:
        kinds |> Enum.chunk_every(2, 1, :discard) |> Enum.count(&(&1 == [:follow_up, :follow_up])),
      grounded: grounded(transcript),
      near_script: Enum.count(transcript, &near_script?(&1.question)),
      level_leaks: Enum.count(transcript, &Report.leak?(&1.question))
    }
  end

  defp grounded(transcript) do
    {counts, _} =
      Enum.map_reduce(transcript, MapSet.new(), fn entry, said ->
        hit = MapSet.size(MapSet.intersection(distinctive(entry.question), said)) >= 2
        {hit, MapSet.union(said, distinctive(entry.answer))}
      end)

    case tl_or_empty(counts) do
      [] -> nil
      later -> Enum.count(later, & &1) / length(later)
    end
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  @doc false
  def distinctive(nil), do: MapSet.new()

  def distinctive(text) do
    ~r/\p{L}{5,}/u
    |> Regex.scan(text |> String.downcase() |> String.replace("'", ""))
    |> List.flatten()
    |> Enum.reject(&(&1 in @common))
    |> MapSet.new()
  end

  @doc "Whether a question is close to one of the rubric's guidance questions."
  @spec near_script?(String.t()) :: boolean()
  def near_script?(question) do
    words = words(question)
    Enum.any?(@guidance, &(jaccard(words, words(&1)) >= 0.5))
  end

  defp words(text) do
    ~r/\p{L}{4,}/u |> Regex.scan(String.downcase(text)) |> List.flatten() |> MapSet.new()
  end

  defp jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end

  @doc "Totals and means over many runs' measures."
  @spec aggregate([map()]) :: map()
  def aggregate(measures) do
    grounded = for %{grounded: g} <- measures, is_number(g), do: g
    questions = Enum.map(measures, & &1.questions)

    %{
      runs: length(measures),
      questions: Enum.sum(questions),
      questions_per_run:
        if(measures == [], do: nil, else: Enum.sum(questions) / length(measures)),
      follow_ups: measures |> Enum.map(& &1.follow_ups) |> Enum.sum(),
      consecutive_follow_ups: measures |> Enum.map(& &1.consecutive_follow_ups) |> Enum.sum(),
      grounded: if(grounded == [], do: nil, else: Enum.sum(grounded) / length(grounded)),
      near_script: measures |> Enum.map(& &1.near_script) |> Enum.sum(),
      level_leaks: measures |> Enum.map(& &1.level_leaks) |> Enum.sum()
    }
  end
end
