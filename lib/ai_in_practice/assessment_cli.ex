defmodule AiInPractice.AssessmentCLI do
  @moduledoc """
  Runs one conversation in a terminal and prints both reports' content, to
  try the engine without the screens (`mix assessment.try`).

      mix assessment.try ROLE_GROUP [--fake] [--questions N]

  ROLE_GROUP is one of the `AiInPractice.RoleGroups` ids, e.g. `finance`.
  `--fake` uses the fake model (`--questions` sets how many it asks);
  otherwise the configured model is used, which needs
  `OPENROUTER_API_KEY`. Type `/finish` to finish early.

  Like a real session, nothing is saved: the conversation and the report
  exist only in this process and on your screen.
  """

  alias AiInPractice.Assessment
  alias AiInPractice.Assessment.{Report, Session}
  alias AiInPractice.{LLM, RoleGroups, Rubric}

  @usage "usage: mix assessment.try ROLE_GROUP [--fake] [--questions N]\nrole groups: " <>
           Enum.map_join(RoleGroups.all(), ", ", &Atom.to_string/1)

  @doc """
  Runs the conversation on standard input and output. Returns `:ok`, or
  `{:error, message}`. `opts[:llm]` and `opts[:reading]` override the
  model client and the reading list (tests).
  """
  @spec run([String.t()], keyword()) :: :ok | {:error, String.t()}
  def run(argv, opts \\ []) do
    with {:ok, group, client} <- parse(argv, opts),
         {:ok, id} <-
           Assessment.start(group,
             llm: client,
             reading: Keyword.get(opts, :reading, &AiInPractice.Reading.active_items/0)
           ) do
      IO.puts("A conversation for #{RoleGroups.name(group)}. Type /finish to finish early.\n")
      # A session that has already stopped has sent its event.
      ref = if pid = Session.whereis(id), do: Process.monitor(pid)
      result = loop(id, ref)
      if ref, do: Process.demonitor(ref, [:flush])
      result
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "could not start: #{inspect(reason)}"}
    end
  end

  defp parse(argv, opts) do
    case OptionParser.parse(argv, strict: [fake: :boolean, questions: :integer]) do
      {flags, [role], []} ->
        with {:ok, group} <- parse_group(role) do
          {:ok, group, client(flags, opts)}
        end

      _ ->
        {:error, @usage}
    end
  end

  defp parse_group(role) do
    case RoleGroups.parse(role) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, "unknown role group #{inspect(role)}\n" <> @usage}
    end
  end

  defp client(flags, opts) do
    cond do
      opts[:llm] -> opts[:llm]
      flags[:fake] -> {AiInPractice.LLM.Fake, questions: Keyword.get(flags, :questions, 5)}
      true -> LLM.client()
    end
  end

  defp loop(id, ref) do
    receive do
      {Assessment, ^id, {:question, %{number: n, text: text}}} ->
        IO.puts("#{n}. #{text}")
        answer(id)
        loop(id, ref)

      {Assessment, ^id, {:closed, reason}} ->
        IO.puts("\nThe conversation is over (#{reason}). Writing the reports...\n")
        loop(id, ref)

      {Assessment, ^id, {:report, report}} ->
        IO.puts(render(report))
        Assessment.stop(id)
        :ok

      {Assessment, ^id, {:failed, reason}} ->
        {:error, "the session stopped: #{reason}"}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, "the session stopped unexpectedly"}
    end
  end

  defp answer(id) do
    case IO.gets("> ") do
      input when input in [:eof, nil] ->
        Assessment.finish_early(id)

      {:error, _} ->
        Assessment.finish_early(id)

      input ->
        input |> String.trim() |> send_answer(id)
    end
  end

  defp send_answer("/finish", id), do: Assessment.finish_early(id)

  defp send_answer(text, id) do
    case Assessment.answer(id, text) do
      :ok ->
        IO.puts("")

      {:error, reason} ->
        IO.puts("(#{reason}, try again)")
        answer(id)
    end
  end

  @doc "The report as plain text, internal levels included, for trying the engine."
  @spec render(Report.t()) :: String.t()
  def render(%Report{} = r) do
    """
    SUMMARY
    #{r.summary}

    #{r.overall}

    #{Enum.map_join(r.areas, "\n", &area/1)}
    STRENGTHS
    #{Enum.map_join(r.strengths, "\n", &"- #{&1.point} #{&1.evidence}")}

    MAIN GAP
    #{r.main_gap}

    NEXT STEPS
    - In the next two weeks: #{r.next_steps.first_two_weeks.step} (#{r.next_steps.first_two_weeks.how_you_will_know})
    #{Enum.map_join(r.next_steps.later, "\n", &"- #{&1}")}

    READING PICKS: #{inspect(r.reading_picks)}

    FOR THE ASSESSOR
    #{Enum.map_join(r.assessor_next_steps, "\n", &"- #{&1}")}

    FOLLOW-UP QUESTIONS
    #{Enum.map_join(r.follow_up_questions, "\n", &"- #{&1.question} Listen for: #{&1.listen_for}")}
    #{if r.manipulation_attempted, do: "\n" <> Report.manipulation_note(), else: ""}
    (dropped: #{r.dropped.quotes} quotes, #{r.dropped.reading_picks} reading picks)
    """
  end

  defp area(a) do
    """
    #{String.upcase(Rubric.area_name(a.area))} [internal: #{a.level}, #{a.confidence}]
    #{a.description} #{a.confidence_in_words}
    #{Enum.map_join(a.quotes, "\n", &"  \"#{&1}\"")}
    Strong answer: #{a.strong_answer}
    Shortfall: #{a.shortfall}
    """
  end
end
