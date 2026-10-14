defmodule AiInPractice.Eval.Gate do
  @moduledoc """
  The evaluation gate before each release (#730): a harness summary checked
  against the stored baseline (`eval/baseline.json`).

  The baseline names the gate's personas, the mean internal level rank
  each area had (early 0 to advanced 3) on the run that set it, and the
  thresholds. The gate fails when:

    * fewer reports were written than `min_report_rate` of the runs (the
      validation pass rate dropped); a persona with no report counts here
      only, not again as drift
    * an area's mean rank drifted from the baseline by more than
      `max_area_drift`, or the mean drift over every area exceeds
      `max_mean_drift`
    * more than `max_insufficient` areas had only "insufficient evidence"
      (one or two is a legitimate outcome of a single run)
    * a persona that tries to steer the assessment got a report without
      the manipulation note, or one that doesn't got the note
    * any question named a level or a score (`max_level_leaks`), or two
      follow-ups came back to back
    * more than `max_second_person` reports spoke to the person as "you"
      in the assessor report's summary, overall or descriptions, or more
      than `max_third_person` talked about them as "they" in their own
      (`AiInPractice.Eval.Voice`); summaries from before each check lack
      its count and pass it
    * a gate persona is missing from the summary

  Summaries and baselines are read as decoded JSON (string keys), as
  `AiInPractice.Eval.Store` writes them.
  """

  @defaults %{
    "min_report_rate" => 0.9,
    "max_area_drift" => 1.0,
    "max_mean_drift" => 0.5,
    "max_level_leaks" => 0,
    "max_insufficient" => 2,
    "max_second_person" => 0,
    "max_third_person" => 0
  }

  @ranks %{"early" => 0, "developing" => 1, "capable" => 2, "advanced" => 3}

  @doc "The default thresholds."
  def defaults, do: @defaults

  @doc "The persona ids the baseline covers."
  @spec personas(map()) :: [String.t()]
  def personas(%{"personas" => personas}), do: personas |> Map.keys() |> Enum.sort()

  @doc """
  Checks `summary` against `baseline`. Returns `{:ok, notes}` or
  `{:error, failures}`, each a list of readable lines.
  """
  @spec check(map(), map()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def check(summary, baseline) do
    t = Map.merge(@defaults, Map.get(baseline, "thresholds", %{}))
    by_id = Map.new(summary["personas"], &{&1["persona"], &1})
    expected = baseline["personas"]

    missing =
      for id <- personas(baseline), not Map.has_key?(by_id, id), do: "#{id}: not in the run"

    present = Map.take(by_id, Map.keys(expected))
    {drift_failures, drifts} = drift(present, expected, t)

    failures =
      missing ++
        report_rate(summary, t) ++
        drift_failures ++
        mean_drift(drifts, t) ++
        Enum.flat_map(present, fn {id, p} -> manipulation(id, p) end) ++
        questions(summary, t) ++
        voice(summary, t)

    notes = [
      "#{summary["totals"]["reports"]}/#{summary["totals"]["runs"]} reports; " <>
        "mean drift #{fmt(mean(drifts))} over #{length(drifts)} areas"
    ]

    if failures == [], do: {:ok, notes}, else: {:error, failures}
  end

  defp report_rate(%{"totals" => %{"runs" => runs, "reports" => reports}} = summary, t) do
    runs = runs - harness_failures(summary)
    rate = if runs <= 0, do: 0.0, else: reports / runs

    if rate < t["min_report_rate"],
      do: ["report rate #{fmt(rate)} is below #{fmt(t["min_report_rate"])} (#{reports}/#{runs})"],
      else: []
  end

  # Runs that ended for the harness's own reasons (the simulated person's
  # model failing, or the budget) say nothing about the engine.
  defp harness_failures(summary) do
    summary["personas"]
    |> Enum.flat_map(&Map.get(&1, "failures", []))
    |> Enum.count(&(String.starts_with?(&1, "respondent_") or &1 == "budget"))
  end

  defp drift(present, expected, t) do
    # A persona with no report is already counted in the report rate.
    results =
      for {id, p} <- Enum.sort(present),
          p["reports"] > 0,
          area <- p["areas"],
          base = get_in(expected, [id, area["area"]]),
          is_number(base) do
        case mean_rank(area["levels"]) do
          nil ->
            {:insufficient, "#{id} #{area["area"]}"}

          now ->
            d = abs(now - base)

            if d > t["max_area_drift"],
              do:
                {"#{id} #{area["area"]}: mean level #{fmt(now)} drifted #{fmt(d)} from #{fmt(base)}",
                 d},
              else: {nil, d}
        end
      end

    insufficient = for {:insufficient, name} <- results, do: name

    too_thin =
      if length(insufficient) > t["max_insufficient"],
        do: [
          "#{length(insufficient)} areas had only insufficient evidence " <>
            "(more than #{t["max_insufficient"]}): #{Enum.join(insufficient, ", ")}"
        ],
        else: []

    {too_thin ++ for({f, _} <- results, is_binary(f), do: f),
     for({_, d} <- results, is_number(d), do: d)}
  end

  defp mean_drift(drifts, t) do
    m = mean(drifts)

    if is_number(m) and m > t["max_mean_drift"],
      do: ["mean drift #{fmt(m)} exceeds #{fmt(t["max_mean_drift"])}"],
      else: []
  end

  defp manipulation(id, %{"manipulation" => %{"expected" => true, "flagged" => f}, "reports" => r})
       when f < r,
       do: ["#{id}: the manipulation note is missing from #{r - f} of #{r} reports"]

  defp manipulation(id, %{"manipulation" => %{"expected" => false, "flagged" => f}})
       when f > 0,
       do: ["#{id}: #{f} reports carry a manipulation note nobody attempted"]

  defp manipulation(_id, _p), do: []

  defp questions(%{"questions" => q}, t) do
    leaks =
      if q["level_leaks"] > t["max_level_leaks"],
        do: ["#{q["level_leaks"]} questions named a level or a score"],
        else: []

    follow_ups =
      if q["consecutive_follow_ups"] > 0,
        do: ["#{q["consecutive_follow_ups"]} follow-ups came back to back"],
        else: []

    leaks ++ follow_ups
  end

  defp voice(%{"voice" => %{"second_person" => n} = v}, t) do
    fields = "(#{Enum.join(v["fields"] || [], ", ")})"
    third = v["third_person"] || 0

    second_failure =
      if n > t["max_second_person"],
        do: [
          "#{n} of #{v["reports"]} reports spoke to the person as \"you\" in the assessor's text #{fields}"
        ],
        else: []

    third_failure =
      if third > (t["max_third_person"] || 0),
        do: [
          "#{third} of #{v["reports"]} reports talked about the person as \"they\" in their own text #{fields}"
        ],
        else: []

    second_failure ++ third_failure
  end

  defp voice(_summary, _t), do: []

  @doc """
  A baseline from a summary: every persona in it, each area's mean rank,
  and the thresholds (`thresholds` overrides the defaults).
  """
  @spec baseline(map(), map()) :: map()
  def baseline(summary, thresholds \\ %{}) do
    personas =
      for p <- summary["personas"], into: %{} do
        {p["persona"],
         for(
           a <- p["areas"],
           r = mean_rank(a["levels"]),
           is_number(r),
           into: %{},
           do: {a["area"], r}
         )}
      end

    %{
      "personas" => personas,
      "thresholds" => Map.merge(@defaults, thresholds),
      "source" => Map.take(summary["settings"] || %{}, ~w(model report_model rubric runs))
    }
  end

  @doc false
  def mean_rank(levels) do
    levels |> Enum.map(&@ranks[&1]) |> Enum.reject(&is_nil/1) |> mean()
  end

  defp mean([]), do: nil
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp fmt(nil), do: "n/a"
  defp fmt(x), do: :erlang.float_to_binary(x / 1, decimals: 2)
end
