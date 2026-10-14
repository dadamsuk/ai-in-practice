defmodule AiInPractice.Eval.Voice do
  @moduledoc """
  Whether a report keeps to its perspective (#700, #724, #802),
  as `AiInPractice.Assessment.Perspective` defines it: the assessor
  report's summary, overall paragraph and area descriptions are about the
  person, "they", and never speak to them as "you"; the person's own
  versions (`your_summary`, `your_overall`, each area's
  `your_description`) speak to them as "you" and never talk about "this
  person" or open a sentence with "They". Words inside quotation marks are
  the person's own and are skipped.
  """

  alias AiInPractice.Assessment.Perspective

  @doc """
  The assessor-report fields of a report (a run's report, atom or string
  keys) that speak to the person as "you", by name: `"summary"`,
  `"overall"` or `"<area> description"`.
  """
  @spec second_person(map()) :: [String.t()]
  def second_person(report) do
    slips(report, [summary: "summary", overall: "overall"], :description, "description", :they)
  end

  @doc """
  The person's-report fields that talk about them in the third person, by
  name: `"your_summary"`, `"your_overall"` or `"<area> your_description"`.
  """
  @spec third_person(map()) :: [String.t()]
  def third_person(report) do
    slips(
      report,
      [your_summary: "your_summary", your_overall: "your_overall"],
      :your_description,
      "your_description",
      :you
    )
  end

  defp slips(report, top, area_key, area_name, perspective) do
    texts =
      for({key, name} <- top, do: {name, field(report, key)}) ++
        for area <- List.wrap(field(report, :areas)) do
          {"#{field(area, :area)} #{area_name}", field(area, area_key)}
        end

    for {name, text} <- texts,
        is_binary(text),
        not Perspective.keeps?(text, perspective),
        do: name
  end

  @doc """
  How many of `reports` broke their perspective, each way, and where:
  `second_person` counts reports that said "you" in the assessor report's
  text, `third_person` those that said "they" in the person's own.
  """
  @spec aggregate([map()]) :: %{
          reports: non_neg_integer(),
          second_person: non_neg_integer(),
          third_person: non_neg_integer(),
          fields: [String.t()]
        }
  def aggregate(reports) do
    second = Enum.map(reports, &second_person/1)
    third = Enum.map(reports, &third_person/1)

    %{
      reports: length(reports),
      second_person: Enum.count(second, &(&1 != [])),
      third_person: Enum.count(third, &(&1 != [])),
      fields: (second ++ third) |> List.flatten() |> Enum.uniq() |> Enum.sort()
    }
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_other, _key), do: nil
end
