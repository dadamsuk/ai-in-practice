defmodule AiInPractice.Reports.Content do
  @moduledoc """
  What each report says, in order (rubric "Reports", PRD §9), as a list of
  blocks that both the reports screen and the PDF render. Keeping one list
  means the person downloads exactly what they reviewed on screen.

  A block is one of:

    * `{:h2, text}`, `{:h3, text}`: headings
    * `{:p, text}`: a paragraph; `{:strong, text}`: a paragraph in bold
    * `{:labelled, label, text}`: a mono label, then a paragraph
    * `{:quote, text}`: the person's own words
    * `{:list, [text]}`: a list
    * `{:reading, %{title: _, url: _, meta: _, why: _, note: _}}`: a resource
      for the person's next steps: its title and link, a line of facts
      (author, format, cost), why it was chosen for them, and what it is
    * `{:statement, text}`: the assessor report's standing statement

  The header facts (`header/1`) are `{label, value}` pairs in mono.

  Each area's internal `level` and `confidence` are never used here: only
  the words written for the person (rubric, "How the assessment is
  expressed").
  """

  alias AiInPractice.Assessment.Report
  alias AiInPractice.{Reading, RoleGroups, Rubric}

  @type block ::
          {:h2 | :h3 | :p | :strong | :quote | :statement, String.t()}
          | {:labelled, String.t(), String.t()}
          | {:list, [String.t()]}
          | {:reading,
             %{
               title: String.t(),
               url: String.t() | nil,
               meta: String.t() | nil,
               why: String.t() | nil,
               note: String.t() | nil
             }}

  @typedoc """
  What the report needs to know about the session: the role group, the
  date, text or voice, and the kind of link (`:candidate` for a recruiter's
  link, `:individual`). `sample: true` marks a report written for a
  fictional person (`mix eval.sample`, #724); a real session never sets it.
  """
  @type meta :: %{
          required(:role_group) => RoleGroups.t(),
          required(:date) => Date.t(),
          required(:mode) => :text | :voice,
          required(:link_kind) => :candidate | :individual,
          optional(:sample) => boolean(),
          optional(:quick) => boolean()
        }

  @statement "This report is a conversation starter. The identity of the person who took part has not been checked. It is one input to human judgement, never a decision on its own."

  @sample "a fictional person, made up for illustration"

  @quick "quick, a trial run: three or four questions, not a full conversation"

  @doc "The assessor report's standing statement, shown in its header and on every page."
  def statement, do: @statement

  @doc "What a sample report says it is, in its header and its signed content."
  def sample, do: @sample

  @doc "What a quick session's report says it is, in its header and its signed content."
  def quick, do: @quick

  @doc "The report's title for an audience."
  @spec title(:candidate | :assessor) :: String.t()
  def title(:candidate), do: "Your report"
  def title(:assessor), do: "Assessor report"

  @doc "The header facts, as `{label, value}` pairs."
  @spec header(meta()) :: [{String.t(), String.t()}]
  def header(meta) do
    [
      if(Map.get(meta, :sample), do: {"sample", @sample}, else: []),
      {"role group", RoleGroups.name(meta.role_group)},
      {"date", Calendar.strftime(meta.date, "%-d %B %Y")},
      {"answers", if(meta.mode == :voice, do: "spoken", else: "typed")},
      {"link", if(meta.link_kind == :individual, do: "individual", else: "from a recruiter")},
      if(Map.get(meta, :quick), do: {"session", @quick}, else: [])
    ]
    |> List.flatten()
  end

  @doc "The blocks of the person's own report."
  @spec candidate(Report.t()) :: [block()]
  def candidate(%Report{} = report) do
    List.flatten([
      {:h2, "Summary"},
      {:p, report.your_summary},
      {:p, report.your_overall},
      {:h2, "The five areas"},
      for area <- report.areas do
        [
          {:h3, Rubric.area_name(area.area)},
          {:p, area.your_description},
          {:labelled, "how sure this is", area.your_confidence_in_words}
        ]
      end,
      {:h2, "What you are doing well"},
      for(s <- report.strengths, do: [{:strong, s.point}, maybe(:p, s.evidence)]),
      {:h2, "The main gap"},
      {:p, report.main_gap},
      {:h2, "Next steps"},
      {:h3, "In the next two weeks"},
      {:p, report.next_steps.first_two_weeks.step},
      {:labelled, "how you will know it helped",
       report.next_steps.first_two_weeks.how_you_will_know},
      if(report.next_steps.later == [],
        do: [],
        else: [{:h3, "After that"}, {:list, report.next_steps.later}]
      ),
      reading(report.reading_picks),
      {:h2, "What the assessor report contains"},
      {:p,
       "The assessor report repeats the summary, describes each area with short quotes from your answers, says what a strong answer would have included for your role, and suggests what to explore with you next and questions to ask in person. It does not include this report's next steps or resources. You can read it in full before deciding whether to send it to anyone."}
    ])
  end

  @doc "The blocks of the assessor report."
  @spec assessor(Report.t()) :: [block()]
  def assessor(%Report{} = report) do
    List.flatten([
      {:statement, @statement},
      if(report.manipulation_attempted, do: {:strong, Report.manipulation_note()}, else: []),
      {:h2, "Summary"},
      {:p, report.summary},
      {:p, report.overall},
      {:h2, "The five areas"},
      for area <- report.areas do
        [
          {:h3, Rubric.area_name(area.area)},
          {:p, area.description},
          for(q <- area.quotes, do: {:quote, q}),
          {:labelled, "how sure this is", area.confidence_in_words},
          {:labelled, "a strong answer for this role would include", area.strong_answer},
          {:labelled, "where this one fell short", area.shortfall}
        ]
      end,
      {:h2, "What to explore next"},
      {:list, report.assessor_next_steps},
      {:h2, "Questions to ask in person"},
      for q <- report.follow_up_questions do
        [{:strong, q.question}, maybe_labelled("listen for", q.listen_for)]
      end
    ])
  end

  @doc """
  The header facts of a signed assessor payload (`AiInPractice.Reports.Payload`),
  for the check page: the same facts as `header/1`, read from what was signed.
  """
  @spec signed_header(map()) :: [{String.t(), String.t()}]
  def signed_header(payload) do
    [
      if(is_binary(payload["sample"]), do: {"sample", payload["sample"]}, else: []),
      {"role group", payload["role_group_name"]},
      {"date", signed_date(payload["date"])},
      {"answers", payload["answers"]},
      {"link", payload["link"]},
      if(is_binary(payload["session"]), do: {"session", payload["session"]}, else: [])
    ]
    |> List.flatten()
  end

  defp signed_date(iso) do
    case Date.from_iso8601(to_string(iso)) do
      {:ok, date} -> Calendar.strftime(date, "%-d %B %Y")
      _ -> to_string(iso)
    end
  end

  @doc """
  The blocks of a signed assessor payload, in the order `assessor/1` puts
  them, so the check page shows the signed content laid out as the report is.
  """
  @spec signed_blocks(map()) :: [block()]
  def signed_blocks(payload) do
    List.flatten([
      {:statement, payload["statement"]},
      maybe(:strong, payload["manipulation_note"]),
      {:h2, "Summary"},
      maybe(:p, payload["summary"]),
      maybe(:p, payload["overall"]),
      {:h2, "The five areas"},
      for area <- List.wrap(payload["areas"]) do
        [
          {:h3, area["name"]},
          maybe(:p, area["description"]),
          for(q <- List.wrap(area["quotes"]), do: {:quote, q}),
          maybe_labelled("how sure this is", area["confidence_in_words"]),
          maybe_labelled("a strong answer for this role would include", area["strong_answer"]),
          maybe_labelled("where this one fell short", area["shortfall"])
        ]
      end,
      {:h2, "What to explore next"},
      {:list, List.wrap(payload["explore_next"])},
      {:h2, "Questions to ask in person"},
      for q <- List.wrap(payload["follow_up_questions"]) do
        [maybe(:strong, q["question"]), maybe_labelled("listen for", q["listen_for"])]
      end
    ])
  end

  defp reading([]), do: []

  defp reading(picks) do
    items =
      for %{id: id, why: why} <- picks, item = Reading.get_item(id), item != nil do
        {:reading,
         %{
           title: item.title,
           url: item.url,
           meta: meta(item),
           why: why,
           note: blank_nil(item.note)
         }}
      end

    if items == [], do: [], else: [{:h2, "Resources for your next steps"} | items]
  end

  defp meta(item) do
    # Mono is never capitals: the format and cost are lower case.
    facts = [
      item.author,
      item.format && String.downcase(item.format),
      item.cost && String.downcase(item.cost)
    ]

    case Enum.filter(facts, &(is_binary(&1) and &1 != "")) do
      [] -> nil
      facts -> Enum.join(facts, " · ")
    end
  end

  defp blank_nil(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp blank_nil(_), do: nil

  defp maybe(kind, text) when is_binary(text),
    do: if(String.trim(text) == "", do: [], else: {kind, text})

  defp maybe(_kind, _text), do: []

  defp maybe_labelled(label, text) when is_binary(text),
    do: if(String.trim(text) == "", do: [], else: {:labelled, label, text})

  defp maybe_labelled(_label, _text), do: []

  @doc "Every piece of text in a list of blocks, in order, for tests and the PDF."
  @spec texts([block()]) :: [String.t()]
  def texts(blocks) do
    Enum.flat_map(blocks, fn
      {:labelled, label, text} ->
        [label, text]

      {:list, items} ->
        items

      {:reading, item} ->
        Enum.reject([item.title, item.url, item.meta, item.why, item.note], &is_nil/1)

      {_kind, text} ->
        [text]
    end)
  end
end
