defmodule AiInPractice.Eval.Voice do
  @moduledoc """
  Whether a report keeps to its voice (#700, #724): the text both reports
  share (summary, overall, each area's description) is about the person,
  "they", and never speaks to them as "you", since the assessor reads it
  too. Words inside quotation marks are the person's own and are skipped.
  """

  @second_person ~r/\b(you|your|yours|yourself|yourselves)\b/iu
  @quoted ~r/"[^"]*"|“[^”]*”/u

  @doc """
  The shared fields of a report (a run's report, atom or string keys) that
  speak to the person as "you", by name: `"summary"`, `"overall"` or
  `"<area> description"`.
  """
  @spec second_person(map()) :: [String.t()]
  def second_person(report) do
    shared =
      [{"summary", field(report, :summary)}, {"overall", field(report, :overall)}] ++
        for area <- List.wrap(field(report, :areas)) do
          {"#{field(area, :area)} description", field(area, :description)}
        end

    for {name, text} <- shared,
        is_binary(text),
        text |> without_quotes() |> String.match?(@second_person),
        do: name
  end

  @doc "How many of `reports` speak to the person as \"you\" in shared text, and where."
  @spec aggregate([map()]) :: %{
          reports: non_neg_integer(),
          second_person: non_neg_integer(),
          fields: [String.t()]
        }
  def aggregate(reports) do
    found = Enum.map(reports, &second_person/1)

    %{
      reports: length(reports),
      second_person: Enum.count(found, &(&1 != [])),
      fields: found |> List.flatten() |> Enum.uniq() |> Enum.sort()
    }
  end

  defp without_quotes(text), do: String.replace(text, @quoted, "")

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_other, _key), do: nil
end
