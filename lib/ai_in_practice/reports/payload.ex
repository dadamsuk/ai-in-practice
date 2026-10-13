defmodule AiInPractice.Reports.Payload do
  @moduledoc """
  The content of the assessor report that is signed and embedded in its
  PDF (PRD §9, #707): exactly what the report says, structured, so a
  verifier (epic 10) can show it beside the visible PDF and any edit stands
  out.

  **Only the rendered fields.** Each area's internal `level` and
  `confidence` are left out, as are the report's validation counts
  (`dropped`): the rubric says levels are "used for consistency, never
  displayed", and anything embedded in the PDF can be extracted by whoever
  holds it. Consistency checks (epic 8) read them from memory instead. The
  link id is left out too: the payload says what kind of link it was, not
  which.

  A sample report (`sample: true` in the meta, #724) carries a `"sample"`
  key saying so, so the check page shows it is fictional. Real reports have
  no such key, so their payloads are unchanged. A quick session's report
  (`quick: true`) carries a `"session"` key the same way, so it cannot pass
  as a full one.

  The payload holds strings, integers, booleans, `null`, lists and maps
  only, so it encodes canonically (`AiInPractice.Reports.Canonical`).
  """

  alias AiInPractice.Assessment.Report
  alias AiInPractice.Reports.Content
  alias AiInPractice.{RoleGroups, Rubric, Version}

  @format "ai-in-practice/assessor-report/1"

  @doc "The payload's format identifier, which changes if its shape does."
  def format, do: @format

  @doc "The signed payload of the assessor report."
  @spec assessor(Report.t(), Content.meta()) :: map()
  def assessor(%Report{} = report, meta) do
    payload = %{
      "format" => @format,
      "role_group" => Atom.to_string(meta.role_group),
      "role_group_name" => RoleGroups.name(meta.role_group),
      "date" => Date.to_iso8601(meta.date),
      "answers" => if(meta.mode == :voice, do: "spoken", else: "typed"),
      "link" => if(meta.link_kind == :individual, do: "individual", else: "from a recruiter"),
      "versions" => %{
        "code" => Version.code_version(),
        "rubric" => Version.rubric_version(),
        "model" => Version.model()
      },
      "statement" => Content.statement(),
      "manipulation_note" =>
        if(report.manipulation_attempted, do: Report.manipulation_note(), else: nil),
      "summary" => report.summary,
      "overall" => report.overall,
      "areas" =>
        for area <- report.areas do
          %{
            "area" => Atom.to_string(area.area),
            "name" => Rubric.area_name(area.area),
            "description" => area.description,
            "quotes" => area.quotes,
            "confidence_in_words" => area.confidence_in_words,
            "strong_answer" => area.strong_answer,
            "shortfall" => area.shortfall
          }
        end,
      "explore_next" => report.assessor_next_steps,
      "follow_up_questions" =>
        for(
          q <- report.follow_up_questions,
          do: %{"question" => q.question, "listen_for" => q.listen_for}
        )
    }

    payload
    |> then(&if Map.get(meta, :sample), do: Map.put(&1, "sample", Content.sample()), else: &1)
    |> then(&if Map.get(meta, :quick), do: Map.put(&1, "session", Content.quick()), else: &1)
  end
end
