defmodule AiInPractice.Assessment.Report do
  @moduledoc """
  The validated content of both reports (PRD §8.2, rubric "Reports"), held
  only in memory.

  `generate/4` makes the report call and validates the result in code:

    * a quote that is not a verbatim substring of one of the person's
      answers (after whitespace and typographic-quote normalisation) is
      dropped;
    * a reading pick that is not an active reading-list id is dropped, and
      a pick's "why" that names a level or a score is dropped (the pick
      stays);
    * a level label or a numeric score in any rendered text field rejects
      the output;
    * a missing or empty section rejects the output;
    * text that breaks its report's perspective (`AiInPractice.Assessment.Perspective`:
      the person's report says "you", the assessor report "they")
      rejects the output, and a pick's "why" that does is dropped.

  Rejected output is regenerated once, with the rules it broke and where
  (never its text) added to the request; a second rejection is
  `{:error, :report_invalid}`, which the UI turns into an apology. Each
  rejection emits `[:ai_in_practice, :report, :rejected]` telemetry whose
  metadata is the `{rule, path}` list only.

  `level` and `confidence` on each area are internal (rubric, "How the
  assessment is expressed") and must never be rendered.

  `inspect/1` shows no content, so a report that ends up in a log or crash
  report shows no words.
  """

  require Logger

  alias AiInPractice.Assessment.{Perspective, ReportPrompt, Transcript}
  alias AiInPractice.LLM
  alias AiInPractice.Rubric

  defstruct [
    :role_group,
    :summary,
    :overall,
    :your_summary,
    :your_overall,
    :areas,
    :strengths,
    :main_gap,
    :next_steps,
    :reading_picks,
    :assessor_next_steps,
    :follow_up_questions,
    manipulation_attempted: false,
    dropped: %{quotes: 0, reading_picks: 0}
  ]

  @type t :: %__MODULE__{}

  @level_atoms Map.new(
                 ~w(early developing capable advanced insufficient_evidence)a,
                 &{Atom.to_string(&1), &1}
               )
  @confidence_atoms %{"high" => :high, "medium" => :medium, "low" => :low}

  @manipulation_note "The transcript contained attempts to direct the assessment. They were ignored."

  @doc "The assessor-report note shown when the transcript tried to direct the assessment."
  def manipulation_note, do: @manipulation_note

  @doc """
  Generates and validates the report for a finished conversation. Model
  errors come back as their `AiInPractice.LLM` class.
  """
  @spec generate(
          AiInPractice.RoleGroups.t(),
          Transcript.t(),
          [AiInPractice.Reading.Item.t()],
          LLM.client()
        ) ::
          {:ok, t()} | {:error, LLM.error_class() | :report_invalid}
  def generate(group, transcript, reading, client \\ LLM.client()) do
    request = ReportPrompt.request(group, transcript, reading)
    reading_ids = Enum.map(reading, & &1.id)
    attempt(request, group, transcript, reading_ids, client, 2)
  end

  defp attempt(request, group, transcript, reading_ids, client, attempts_left) do
    with {:ok, %{data: data}} <- LLM.complete(request, client),
         {:ok, report} <- validate(data, group, transcript, reading_ids) do
      {:ok, report}
    else
      {:error, {:invalid, problems}} when attempts_left > 1 ->
        rejected(problems)
        Logger.warning("report rejected (#{summarise(problems)}), regenerating once")
        request = ReportPrompt.with_feedback(request, problems)
        attempt(request, group, transcript, reading_ids, client, attempts_left - 1)

      {:error, {:invalid, problems}} ->
        rejected(problems)
        Logger.warning("report rejected again (#{summarise(problems)}), giving up")
        {:error, :report_invalid}

      {:error, class} ->
        {:error, class}
    end
  end

  # For the evaluation harness, which counts rejections by rule and path.
  # Like the log line, it carries no text from the report.
  defp rejected(problems) do
    :telemetry.execute([:ai_in_practice, :report, :rejected], %{count: 1}, %{problems: problems})
  end

  # Field paths and rule names only: never the offending text.
  defp summarise(problems),
    do: Enum.map_join(problems, ", ", fn {rule, path} -> "#{rule} at #{path}" end)

  @doc """
  Validates the model's JSON and builds the report. Returns
  `{:error, {:invalid, [{rule, path}]}}` when it must be regenerated.
  """
  @spec validate(map() | nil, AiInPractice.RoleGroups.t(), Transcript.t(), [integer()]) ::
          {:ok, t()} | {:error, {:invalid, [{atom(), String.t()}]}}
  def validate(data, group, transcript, reading_ids) when is_map(data) do
    data = flatten(data)

    case missing(data) do
      [] ->
        answers = transcript |> Transcript.answers() |> Enum.map(&normalise/1)
        report = build(data, group, answers, reading_ids, transcript)

        problems =
          Enum.map(leaks(report), &{:level_or_score, schema_path(&1)}) ++
            Enum.map(off_perspective(report), &{:perspective, schema_path(&1)})

        case problems do
          [] -> {:ok, report}
          problems -> {:error, {:invalid, problems}}
        end

      paths ->
        {:error, {:invalid, Enum.map(paths, &{:missing, schema_path(&1)})}}
    end
  end

  def validate(_data, _group, _transcript, _reading_ids),
    do: {:error, {:invalid, [missing: "report"]}}

  ## The person's report

  # Everything that speaks to the person comes in one object, "your_report"
  # (#802): its summary, overall paragraph, a description per area, the
  # strengths, the main gap and the next steps. Here it is laid flat, beside
  # the assessor's text, as the report keeps it.
  @yours ~w(strengths main_gap next_steps)

  defp flatten(data) do
    yours = if is_map(data["your_report"]), do: data["your_report"], else: %{}
    descriptions = if is_map(yours["areas"]), do: yours["areas"], else: %{}

    areas =
      case data["areas"] do
        areas when is_list(areas) -> Enum.map(areas, &with_yours(&1, descriptions))
        other -> other
      end

    data
    |> Map.drop(["your_report" | @yours])
    |> Map.merge(Map.take(yours, @yours))
    |> Map.merge(%{
      "your_summary" => yours["summary"],
      "your_overall" => yours["overall"],
      "areas" => areas
    })
  end

  # An area with the person's version of its description and confidence.
  defp with_yours(%{} = area, descriptions) do
    yours =
      case descriptions[area["area"]] do
        %{} = yours -> yours
        _ -> %{}
      end

    Map.merge(area, %{
      "your_description" => yours["description"],
      "your_confidence_in_words" => yours["confidence_in_words"]
    })
  end

  defp with_yours(area, _descriptions), do: area

  # A path as the schema spells it, for the regeneration note and the logs.
  @doc false
  def schema_path("your_summary"), do: "your_report.summary"
  def schema_path("your_overall"), do: "your_report.overall"

  def schema_path("areas." <> rest) do
    case String.split(rest, ".") do
      [area, "your_description"] -> "your_report.areas.#{area}.description"
      [area, "your_confidence_in_words"] -> "your_report.areas.#{area}.confidence_in_words"
      _ -> "areas." <> rest
    end
  end

  def schema_path(path) do
    if Enum.any?(@yours, &(path == &1 or String.starts_with?(path, &1 <> "."))),
      do: "your_report." <> path,
      else: path
  end

  ## Required sections

  defp missing(data) do
    [
      text?(data, "summary"),
      text?(data, "overall"),
      text?(data, "your_summary"),
      text?(data, "your_overall"),
      text?(data, "main_gap"),
      areas_missing(data["areas"]),
      list_of?(data, "strengths", 1, &(text?(&1, "point") == [] and text?(&1, "evidence") == [])),
      next_steps_missing(data["next_steps"]),
      list_of?(data, "assessor_next_steps", 1, &nonblank?/1),
      list_of?(
        data,
        "follow_up_questions",
        2,
        &(text?(&1, "question") == [] and text?(&1, "listen_for") == [])
      ),
      if(is_list(data["reading_picks"]), do: [], else: ["reading_picks"]),
      if(is_boolean(data["manipulation_attempted"]), do: [], else: ["manipulation_attempted"])
    ]
    |> List.flatten()
  end

  # A pick is {"id", "why"}; a bare id (an older shape) has no why.
  defp pick(%{"id" => id} = p) when is_integer(id), do: [%{id: id, why: why(p["why"])}]
  defp pick(id) when is_integer(id), do: [%{id: id, why: nil}]
  defp pick(_), do: []

  defp why(text) do
    if nonblank?(text) and not leak?(text) and Perspective.keeps?(text, :you),
      do: String.trim(text),
      else: nil
  end

  defp text?(map, key) when is_map(map), do: if(nonblank?(map[key]), do: [], else: [key])
  defp text?(_map, key), do: [key]

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp list_of?(data, key, min, valid?) do
    case data[key] do
      list when is_list(list) -> if Enum.count(list, valid?) >= min, do: [], else: [key]
      _ -> [key]
    end
  end

  defp next_steps_missing(%{"first_two_weeks" => first} = steps) do
    first_missing = text?(first, "step") ++ text?(first, "how_you_will_know")
    later_missing = if is_list(steps["later"]), do: [], else: ["later"]
    Enum.map(first_missing ++ later_missing, &"next_steps.#{&1}")
  end

  defp next_steps_missing(_), do: ["next_steps"]

  defp areas_missing(areas) when is_list(areas) do
    by_id = Map.new(areas, fn area -> {is_map(area) && area["area"], area} end)

    Enum.flat_map(Rubric.areas(), &area_missing(&1, by_id[Atom.to_string(&1)]))
  end

  defp areas_missing(_), do: ["areas"]

  defp area_missing(id, nil), do: ["areas.#{id}"]

  defp area_missing(id, area) do
    texts =
      Enum.flat_map(
        ~w(description your_description confidence_in_words your_confidence_in_words strong_answer shortfall),
        &text?(area, &1)
      )

    checks = [
      {"level", area["level"] in Map.keys(@level_atoms)},
      {"confidence", area["confidence"] in Map.keys(@confidence_atoms)},
      {"quotes", is_list(area["quotes"])}
    ]

    (texts ++ for({key, false} <- checks, do: key))
    |> Enum.map(&"areas.#{id}.#{&1}")
  end

  ## Building, with quotes and reading picks filtered

  defp build(data, group, answers, reading_ids, transcript) do
    areas =
      for id <- Rubric.areas() do
        area = Enum.find(data["areas"], &(is_map(&1) and &1["area"] == Atom.to_string(id)))
        quotes = Enum.filter(area["quotes"], &is_binary/1)

        %{
          area: id,
          level: Map.fetch!(@level_atoms, area["level"]),
          confidence: Map.fetch!(@confidence_atoms, area["confidence"]),
          description: area["description"],
          your_description: area["your_description"],
          confidence_in_words: area["confidence_in_words"],
          your_confidence_in_words: area["your_confidence_in_words"],
          quotes: Enum.filter(quotes, &verbatim?(&1, answers)),
          strong_answer: area["strong_answer"],
          shortfall: area["shortfall"],
          offered_quotes: length(quotes)
        }
      end

    picks = data["reading_picks"]

    kept_picks =
      picks
      |> Enum.flat_map(&pick/1)
      |> Enum.filter(&(&1.id in reading_ids))
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(3)

    dropped_quotes = Enum.sum(for a <- areas, do: a.offered_quotes - length(a.quotes))

    %__MODULE__{
      role_group: group,
      summary: data["summary"],
      overall: data["overall"],
      your_summary: data["your_summary"],
      your_overall: data["your_overall"],
      areas: Enum.map(areas, &Map.delete(&1, :offered_quotes)),
      strengths:
        for(
          s <- data["strengths"],
          is_map(s),
          nonblank?(s["point"]),
          do: %{point: s["point"], evidence: s["evidence"]}
        ),
      main_gap: data["main_gap"],
      next_steps: %{
        first_two_weeks: %{
          step: data["next_steps"]["first_two_weeks"]["step"],
          how_you_will_know: data["next_steps"]["first_two_weeks"]["how_you_will_know"]
        },
        later: data["next_steps"]["later"] |> Enum.filter(&nonblank?/1) |> Enum.take(3)
      },
      reading_picks: kept_picks,
      assessor_next_steps: Enum.filter(data["assessor_next_steps"], &nonblank?/1),
      follow_up_questions:
        for(
          q <- data["follow_up_questions"],
          is_map(q),
          nonblank?(q["question"]),
          do: %{question: q["question"], listen_for: q["listen_for"]}
        )
        |> Enum.take(3),
      manipulation_attempted:
        data["manipulation_attempted"] or manipulation_attempted?(transcript),
      dropped: %{quotes: dropped_quotes, reading_picks: length(picks) - length(kept_picks)}
    }
  end

  @doc false
  # Whitespace collapsed and typographic quotes and dashes made plain, so a
  # quote the model copied faithfully is not dropped for a curly apostrophe.
  def normalise(text) do
    text
    |> String.replace(["‘", "’", "‛", "′"], "'")
    |> String.replace(["“", "”", "″"], "\"")
    |> String.replace(["–", "—"], "-")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc false
  def verbatim?(quote, normalised_answers) do
    quote = quote |> normalise() |> String.trim("\"") |> String.trim()
    quote != "" and Enum.any?(normalised_answers, &String.contains?(&1, quote))
  end

  ## Manipulation (PRD §8.3)

  # A belt to the model's braces: answers that plainly try to direct the
  # assessment are flagged even if the model did not flag them.
  defp manipulation_regex do
    ~r/\b(?:rate|score|mark|grade|assess|rank|place|put)\s+me\s+(?:as|at|a|an|highly|high|top)\b|\bignore\s+(?:all\s+|any\s+|the\s+|your\s+)?(?:previous|prior|above|earlier)?\s*(?:instructions|rules|prompt)\b|\b(?:system prompt|you are now|new instructions)\b/i
  end

  @doc false
  def manipulation_attempted?(transcript) do
    transcript |> Transcript.answers() |> Enum.any?(&Regex.match?(manipulation_regex(), &1))
  end

  ## Level labels and scores in rendered text

  @labels ~w(Early Developing Capable Advanced)

  @doc """
  The paths of rendered text fields that carry a level label or a numeric
  score. Quotes are the person's own words and are not checked.
  """
  @spec leaks(t()) :: [String.t()]
  def leaks(%__MODULE__{} = report) do
    report
    |> rendered_text()
    |> Enum.filter(fn {_path, text} -> leak?(text) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp rendered_text(r),
    do: Enum.map(rendered(r), fn {path, text, _perspective} -> {path, text} end)

  @doc """
  The paths of rendered text fields that break their report's perspective
  (`AiInPractice.Assessment.Perspective`). The follow-up questions are
  for the assessor to ask the person, so they may say "you".
  """
  @spec off_perspective(t()) :: [String.t()]
  def off_perspective(%__MODULE__{} = report) do
    for {path, text, perspective} <- rendered(report),
        perspective != :any,
        not Perspective.keeps?(text, perspective),
        do: path
  end

  # Every rendered text field: its path, its text and its perspective.
  defp rendered(r) do
    [
      {"summary", r.summary, :they},
      {"overall", r.overall, :they},
      {"your_summary", r.your_summary, :you},
      {"your_overall", r.your_overall, :you},
      {"main_gap", r.main_gap, :you},
      {"next_steps.first_two_weeks.step", r.next_steps.first_two_weeks.step, :you},
      {"next_steps.first_two_weeks.how_you_will_know",
       r.next_steps.first_two_weeks.how_you_will_know, :you}
    ] ++
      for(
        a <- r.areas,
        {field, perspective} <- [
          description: :they,
          your_description: :you,
          confidence_in_words: :they,
          your_confidence_in_words: :you,
          strong_answer: :they,
          shortfall: :they
        ],
        do: {"areas.#{a.area}.#{field}", Map.fetch!(a, field), perspective}
      ) ++
      indexed("strengths", r.strengths, fn s -> [{s.point, :you}, {s.evidence, :you}] end) ++
      indexed("next_steps.later", r.next_steps.later, &[{&1, :you}]) ++
      indexed("assessor_next_steps", r.assessor_next_steps, &[{&1, :they}]) ++
      indexed("follow_up_questions", r.follow_up_questions, fn q ->
        [{q.question, :any}, {q.listen_for, :they}]
      end)
  end

  defp indexed(prefix, items, fun) do
    for {item, i} <- Enum.with_index(items),
        {text, perspective} <- fun.(item),
        do: {"#{prefix}.#{i}", text, perspective}
  end

  @doc false
  def leak?(text) when is_binary(text) do
    numeric_score?(text) or labelled_level?(text) or
      Enum.any?(sentences(text), &capitalised_label?/1)
  end

  def leak?(_), do: false

  defp numeric_score?(text) do
    Regex.match?(~r"\b\d{1,3}(?:\.\d+)?\s*/\s*(?:5|10|100)\b", text) or
      Regex.match?(~r/\b\d{1,3}(?:\.\d+)?\s+out\s+of\s+(?:5|10|100)\b/i, text) or
      Regex.match?(
        ~r/\b(?:scored?|scores|rating|rated|grade|graded|level|tier)\s*(?:of|at|:)?\s*\d/i,
        text
      )
  end

  defp labelled_level?(text) do
    labels = "early|developing|capable|advanced|insufficient[ -]evidence"

    Regex.match?(~r/\b(?:#{labels})\s+(?:level|rating|tier|band|grade)\b/i, text) or
      Regex.match?(
        ~r/\b(?:level|rated|rating|graded|grade|placed|scored?|classed|classified)\s*(?:as|at|of|:)?\s*["'“‘]?(?:#{labels})\b/i,
        text
      ) or Regex.match?(~r/["'“‘](?:#{labels})["'”’]/i, text)
  end

  # A level label capitalised where ordinary English would not capitalise
  # it: anywhere but the first word of a sentence, or as the first word
  # when it is followed by a colon, dash or bracket ("Advanced: ...").
  defp capitalised_label?(sentence) do
    words = String.split(sentence, ~r/[^\p{L}:\-–—)(]+/u, trim: true)

    case words do
      [] ->
        false

      [first | rest] ->
        Regex.match?(~r/\A(?:#{Enum.join(@labels, "|")})[:\-–—)]/u, first) or
          Enum.any?(rest, &Enum.member?(@labels, String.trim(&1, ":-–—()"))) or
          Regex.match?(~r/\S\s+Insufficient evidence\b/, sentence)
    end
  end

  defp sentences(text), do: String.split(text, ~r/(?<=[.!?])\s+|\n+/u, trim: true)

  defimpl Inspect do
    def inspect(report, _opts), do: "#Report<#{report.role_group}, redacted>"
  end
end
