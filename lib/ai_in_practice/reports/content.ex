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
    * `{:reading, %{title: _, url: _, note: _}}`: a further-reading entry
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
          | {:reading, %{title: String.t(), url: String.t() | nil, note: String.t() | nil}}

  @typedoc """
  What the report needs to know about the session: the role group, the
  date, text or voice, and the kind of link (`:candidate` for a recruiter's
  link, `:individual`).
  """
  @type meta :: %{
          role_group: RoleGroups.t(),
          date: Date.t(),
          mode: :text | :voice,
          link_kind: :candidate | :individual
        }

  @statement "This report is a conversation starter. The identity of the person who took part has not been checked. It is one input to human judgement, never a decision on its own."

  @doc "The assessor report's standing statement, shown in its header and on every page."
  def statement, do: @statement

  @doc "The report's title for an audience."
  @spec title(:candidate | :assessor) :: String.t()
  def title(:candidate), do: "Your report"
  def title(:assessor), do: "Assessor report"

  @doc "The header facts, as `{label, value}` pairs."
  @spec header(meta()) :: [{String.t(), String.t()}]
  def header(meta) do
    [
      {"role group", RoleGroups.name(meta.role_group)},
      {"date", Calendar.strftime(meta.date, "%-d %B %Y")},
      {"answers", if(meta.mode == :voice, do: "spoken", else: "typed")},
      {"link", if(meta.link_kind == :individual, do: "individual", else: "from a recruiter")}
    ]
  end

  @doc "The blocks of the person's own report."
  @spec candidate(Report.t()) :: [block()]
  def candidate(%Report{} = report) do
    List.flatten([
      {:h2, "Summary"},
      {:p, report.summary},
      {:p, report.overall},
      {:h2, "The five areas"},
      for area <- report.areas do
        [
          {:h3, Rubric.area_name(area.area)},
          {:p, area.description},
          {:labelled, "how sure this is", area.confidence_in_words}
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
       "The assessor report repeats the summary, describes each area with short quotes from your answers, says what a strong answer would have included for your role, and suggests what to explore with you next and questions to ask in person. It does not include this report's next steps or reading. You can read it in full before deciding whether to send it to anyone."}
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

  defp reading([]), do: []

  defp reading(ids) do
    items =
      for id <- ids, item = Reading.get_item(id), item != nil do
        {:reading, %{title: item.title, url: item.url, note: item.note}}
      end

    if items == [], do: [], else: [{:h2, "Further reading"} | items]
  end

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
      {:labelled, label, text} -> [label, text]
      {:list, items} -> items
      {:reading, item} -> Enum.reject([item.title, item.url, item.note], &is_nil/1)
      {_kind, text} -> [text]
    end)
  end
end
