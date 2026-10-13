defmodule AiInPractice.Assessment do
  @moduledoc """
  The assessment engine (PRD §8): an adaptive conversation built from the
  rubric, then a validated report, all held in memory only (PRD §10).

    * `AiInPractice.Assessment.Session`: one process per live
      conversation, with limits, coverage tracking and the report call
    * `AiInPractice.Assessment.ConversationPrompt`: each turn's prompt
    * `AiInPractice.Assessment.ReportPrompt` and
      `AiInPractice.Assessment.Report`: the report call and its validation
    * `AiInPractice.Rubric`: the rubric the prompts are built from
    * `AiInPractice.LLM`: the model client

  Events reach the owner as `{AiInPractice.Assessment, session_id, event}`;
  see `AiInPractice.Assessment.Session`.
  """

  alias AiInPractice.Assessment.Session

  defdelegate start(role_group, opts \\ []), to: Session
  defdelegate limits(quick? \\ false), to: Session
  defdelegate answer(id, text), to: Session
  defdelegate finish_early(id), to: Session
  defdelegate retry_report(id), to: Session
  defdelegate report(id), to: Session
  defdelegate download(id), to: Session
  defdelegate attach(id, check, owner \\ self()), to: Session
  defdelegate stop(id), to: Session
end
