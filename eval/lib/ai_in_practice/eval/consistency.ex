defmodule AiInPractice.Eval.Consistency do
  @moduledoc """
  The consistency summary for a persona's runs (PRD §14): per area, the
  internal levels the reports gave, how far they spread between runs, how
  far they sit from the persona's true level, and how much the written
  descriptions agree.

  Levels are ranked early 0, developing 1, capable 2, advanced 3.
  "Insufficient evidence" has no rank: it is counted, and left out of the
  spread and the error.

  Description agreement is the mean pairwise word overlap (Jaccard, over
  lower-cased words of four letters or more) between runs. It is a rough
  signal: 1.0 is identical wording, and descriptions that agree in
  substance but not in wording score well below it.
  """

  alias AiInPractice.Eval.Persona
  alias AiInPractice.Rubric

  @ranks %{early: 0, developing: 1, capable: 2, advanced: 3}

  @doc "A level's rank, or nil for insufficient evidence."
  @spec rank(atom()) :: 0..3 | nil
  def rank(level), do: Map.get(@ranks, level)

  @doc """
  Summarises one persona's run results (`AiInPractice.Eval.Run` results,
  each with `:report_calls`, the number of report requests it made).
  """
  @spec summarise(Persona.t(), [map()]) :: map()
  def summarise(%Persona{} = persona, results) do
    reports = for %{outcome: :report, report: report} <- results, do: report

    %{
      persona: persona.id,
      role_group: persona.role_group,
      runs: length(results),
      reports: length(reports),
      first_pass: Enum.count(results, &(&1.outcome == :report and &1[:report_calls] == 1)),
      failures: for(%{outcome: :failed, failure: f} <- results, do: f),
      areas: Enum.map(Rubric.areas(), &area(&1, persona.levels[&1], reports)),
      manipulation: %{
        expected: persona.expect_manipulation,
        flagged: Enum.count(reports, & &1.manipulation_attempted)
      }
    }
  end

  defp area(id, truth, reports) do
    found = Enum.map(reports, fn r -> Enum.find(r.areas, &(&1.area == id)) end)
    levels = Enum.map(found, & &1.level)
    ranked = levels |> Enum.map(&rank/1) |> Enum.reject(&is_nil/1)
    deltas = Enum.map(ranked, &(&1 - rank(truth)))

    %{
      area: id,
      truth: truth,
      levels: levels,
      modal: modal(levels),
      agreement: agreement(levels),
      spread: if(ranked == [], do: nil, else: Enum.max(ranked) - Enum.min(ranked)),
      insufficient: Enum.count(levels, &(&1 == :insufficient_evidence)),
      bias: mean(deltas),
      abs_error: mean(Enum.map(deltas, &abs/1)),
      description_overlap: overlap(Enum.map(found, & &1.description))
    }
  end

  @doc "The most common level (ties go to the lower rank), or nil with none."
  @spec modal([atom()]) :: atom() | nil
  def modal([]), do: nil

  def modal(levels) do
    levels
    |> Enum.frequencies()
    |> Enum.max_by(fn {level, n} -> {n, -(rank(level) || 4)} end)
    |> elem(0)
  end

  @doc "The share of runs that gave the modal level, or nil with none."
  @spec agreement([atom()]) :: float() | nil
  def agreement([]), do: nil
  def agreement(levels), do: Enum.count(levels, &(&1 == modal(levels))) / length(levels)

  @doc "The mean, or nil for an empty list."
  @spec mean([number()]) :: float() | nil
  def mean([]), do: nil
  def mean(xs), do: Enum.sum(xs) / length(xs)

  @doc "Mean pairwise word overlap of the texts, or nil for fewer than two."
  @spec overlap([String.t()]) :: float() | nil
  def overlap(texts) when length(texts) < 2, do: nil

  def overlap(texts) do
    sets = Enum.map(texts, &words/1)

    pairs =
      for {a, i} <- Enum.with_index(sets),
          {b, j} <- Enum.with_index(sets),
          i < j,
          do: jaccard(a, b)

    mean(pairs)
  end

  defp words(text) do
    ~r/\p{L}{4,}/u
    |> Regex.scan(String.downcase(text || ""))
    |> List.flatten()
    |> MapSet.new()
  end

  defp jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 1.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end

  @doc """
  Compares two personas' summaries area by area (a fairness pair: the same
  evidence told differently). `shift` is the difference in mean rank,
  second minus first; nil where either has no ranked level.
  """
  @spec compare(map(), map()) :: map()
  def compare(a, b) do
    %{
      personas: {a.persona, b.persona},
      areas:
        for {x, y} <- Enum.zip(a.areas, b.areas) do
          %{area: x.area, modal: {x.modal, y.modal}, shift: shift(x, y)}
        end
    }
  end

  defp shift(x, y) do
    with mx when is_number(mx) <- mean_rank(x.levels),
         my when is_number(my) <- mean_rank(y.levels) do
      my - mx
    end
  end

  defp mean_rank(levels), do: levels |> Enum.map(&rank/1) |> Enum.reject(&is_nil/1) |> mean()
end
