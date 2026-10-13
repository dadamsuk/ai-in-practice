defmodule AiInPractice.Eval.Run do
  @moduledoc """
  One conversation between a persona and the real engine, through the
  engine's public API (`AiInPractice.Assessment`), exactly as the
  candidate screen drives it.

  The result keeps the transcript and the report: this is evaluation data
  about a synthetic person, written by `AiInPractice.Eval.Store` to a
  directory outside the repository and the app, never production data.
  """

  alias AiInPractice.Assessment
  alias AiInPractice.Assessment.Report
  alias AiInPractice.Eval.{Persona, Respondent}

  @type result :: %{
          persona: String.t(),
          run: pos_integer(),
          outcome: :report | :failed,
          failure: atom() | nil,
          closed: atom() | nil,
          transcript: [%{question: String.t(), kind: atom(), answer: String.t() | nil}],
          report: map() | nil,
          question_ms: [non_neg_integer()],
          report_ms: non_neg_integer() | nil,
          elapsed_ms: non_neg_integer()
        }

  @doc """
  Runs `persona` once. `engine` and `respondent` are model clients.
  Options: `:reading` (the reading-list items, default the active ones),
  `:limits` (session limit overrides), `:event_timeout_ms` (default three
  minutes per event).
  """
  @spec run(
          Persona.t(),
          pos_integer(),
          AiInPractice.LLM.client(),
          AiInPractice.LLM.client(),
          keyword()
        ) ::
          result()
  def run(%Persona{} = persona, n, engine, respondent, opts \\ []) do
    started = now()

    state = %{
      persona: persona,
      respondent: respondent,
      timeout: Keyword.get(opts, :event_timeout_ms, :timer.minutes(3)),
      transcript: [],
      question_ms: [],
      asked_at: started,
      closed_at: nil,
      closed: nil
    }

    base = %{persona: persona.id, run: n}

    result =
      case Assessment.start(persona.role_group,
             llm: engine,
             reading: Keyword.get(opts, :reading, &AiInPractice.Reading.active_items/0),
             limits: Keyword.get(opts, :limits, %{})
           ) do
        {:ok, id} ->
          try do
            loop(id, state)
          after
            Assessment.stop(id)
          end

        {:error, reason} ->
          failed(state, reason)
      end

    Map.merge(base, Map.put(result, :elapsed_ms, now() - started))
  end

  defp loop(id, state) do
    receive do
      {Assessment, ^id, {:question, %{text: text, kind: kind}}} ->
        state = %{
          state
          | transcript: state.transcript ++ [%{question: text, kind: kind, answer: nil}],
            question_ms: state.question_ms ++ [now() - state.asked_at]
        }

        respond(id, text, state)

      {Assessment, ^id, {:closed, reason}} ->
        loop(id, %{state | closed: reason, closed_at: now()})

      {Assessment, ^id, {:report, report}} ->
        %{
          outcome: :report,
          failure: nil,
          closed: state.closed,
          transcript: state.transcript,
          report: to_map(report),
          question_ms: state.question_ms,
          report_ms: state.closed_at && now() - state.closed_at
        }

      {Assessment, ^id, {:failed, reason}} ->
        failed(state, reason)
    after
      state.timeout -> failed(state, :timeout)
    end
  end

  defp respond(id, question, state) do
    history = for %{answer: a, question: q} <- state.transcript, a != nil, do: {q, a}

    case Respondent.answer(state.persona, history, question, state.respondent) do
      {:ok, text} ->
        # A refusal here means the session closed meanwhile (the hard
        # stop); its next event says so.
        _ = Assessment.answer(id, text)
        transcript = List.update_at(state.transcript, -1, &%{&1 | answer: text})
        loop(id, %{state | transcript: transcript, asked_at: now()})

      {:error, class} ->
        failed(state, :"respondent_#{class}")
    end
  end

  defp failed(state, reason) do
    %{
      outcome: :failed,
      failure: reason,
      closed: state.closed,
      transcript: state.transcript,
      report: nil,
      question_ms: state.question_ms,
      report_ms: nil
    }
  end

  @doc "The report as plain data, internal levels included, for the run's JSON."
  @spec to_map(Report.t()) :: map()
  def to_map(%Report{} = report) do
    report
    |> Map.from_struct()
    |> Map.put(:manipulation_note, report.manipulation_attempted && Report.manipulation_note())
  end

  defp now, do: System.monotonic_time(:millisecond)
end
