defmodule AiInPractice.LLM.Fake do
  @moduledoc """
  A deterministic stand-in for the model, for tests and for walking the
  journey in development without spending (`FAKE_LLM=1`, dev only).

  With no options it runs a short conversation from a fixed set of
  questions (`:questions`, default 5, then it closes) and writes a valid
  report that quotes the person's answers and picks the first two reading
  ids it is offered.

  Tests pass `responder: fn request -> ... end` to script any reply,
  including `{:error, class}`.

  To walk the error screens, `:fail_turn` (`{n, class}`) fails every turn
  once `n` questions have been asked (`{0, class}`: before the first), and
  `:fail_report` (a class, or `:report_invalid`) fails the report call.
  `:flaky` (`{n, class, attempts}`) fails the turn once `n` questions have
  been asked, and the report, for their first `attempts` tries, then lets
  them through: with `attempts` above `AiInPractice.LLM`'s retries, the
  person sees the answer or the report come back unsent, and sending again
  works. The tries are counted per request and answer, in
  `:persistent_term`, so this is for development only.
  `:report_delay_ms` makes the report take that long, to watch the
  writing screen.
  `modes/0` names the combinations `FAKE_LLM` selects.
  """

  @behaviour AiInPractice.LLM

  alias AiInPractice.Rubric

  @bank [
    personal_use:
      "What is the last piece of real work you used AI for, and what did you do with the result?",
    applying_to_business:
      "Tell me about one AI initiative in your area you were close to. What was the problem, and how did you know whether it worked?",
    leading_adoption: "What have you done that changed how your team uses AI day to day?",
    understanding:
      "When did an AI tool last give you or your team a wrong answer, and how was it spotted?",
    attitude: "What view about AI did you hold a year ago that you have since changed?"
  ]

  @modes %{
    "1" => [],
    "true" => [],
    "spend_refused" => [fail_turn: {0, :spend_refused}],
    "fail_mid" => [fail_turn: {2, :fatal}],
    "report_invalid" => [fail_report: :report_invalid],
    "flaky" => [flaky: {2, :transient, 3}],
    "slow" => [report_delay_ms: 20_000],
    "short" => []
  }

  @doc """
  The `FAKE_LLM` values (dev only): `1` (a normal run), `spend_refused`
  (refused before the first question), `fail_mid` (fails after two
  questions), `report_invalid` (the report cannot be written), `flaky` (the
  third question and the report come back unsent once each), `slow` (the
  report takes 20 seconds) and `short`
  (a normal run; `config/runtime.exs` also sets a one-minute hard stop).
  """
  @spec modes() :: %{String.t() => keyword()}
  def modes, do: @modes

  @impl true
  def request(request, opts) do
    case Keyword.get(opts, :responder) do
      nil -> default(request, opts)
      responder -> responder.(request)
    end
  end

  defp default(%{purpose: :turn} = request, opts) do
    asked = request |> user_text() |> count(~r/<question /)
    limit = Keyword.get(opts, :questions, 5)

    case {Keyword.get(opts, :fail_turn), Keyword.get(opts, :flaky)} do
      {{n, class}, _} when asked >= n ->
        {:error, class}

      {_, {^asked, class, attempts}} ->
        flaky(request, class, attempts, fn -> ok(turn_data(asked, limit)) end)

      _ ->
        ok(turn_data(asked, limit))
    end
  end

  defp default(%{purpose: :report} = request, opts) do
    if delay = Keyword.get(opts, :report_delay_ms), do: Process.sleep(delay)

    case {Keyword.get(opts, :fail_report), Keyword.get(opts, :flaky)} do
      # Missing every section, so it is rejected twice, as a real one would be.
      {:report_invalid, _} ->
        ok(%{"summary" => "Nothing else."})

      {nil, {_n, class, attempts}} ->
        flaky(request, class, attempts, fn -> ok(report_data(request)) end)

      {nil, nil} ->
        ok(report_data(request))

      {class, _} ->
        {:error, class}
    end
  end

  # Fails the first `attempts` tries of this request, then answers. A try
  # is the same purpose and the same last answer.
  defp flaky(request, class, attempts, answer) do
    key = {__MODULE__, :flaky, request.purpose, :erlang.phash2(last_answer(request))}
    tries = :persistent_term.get(key, 0)
    :persistent_term.put(key, tries + 1)
    if tries < attempts, do: {:error, class}, else: answer.()
  end

  defp last_answer(request) do
    request
    |> user_text()
    |> then(&Regex.scan(~r{<answer>\n(.*?)\n</answer>}s, &1))
    |> List.last()
  end

  defp turn_data(asked, limit) when asked >= limit,
    do: %{"question" => "", "kind" => "main", "covered_areas" => all_areas(), "close" => true}

  defp turn_data(asked, _limit) do
    {_area, question} = Enum.at(@bank, rem(asked, length(@bank)))

    covered =
      @bank |> Enum.take(min(asked, length(@bank))) |> Enum.map(&Atom.to_string(elem(&1, 0)))

    %{"question" => question, "kind" => "main", "covered_areas" => covered, "close" => false}
  end

  defp report_data(request) do
    text = user_text(request)
    answers = for [_, a] <- Regex.scan(~r{<answer>\n(.*?)\n</answer>}s, text), do: a
    reading = for [_, id] <- Regex.scan(~r/<reading id="(\d+)">/, text), do: String.to_integer(id)
    report(answers, Enum.take(reading, 2))
  end

  @doc "A complete, valid report payload quoting `answers`, for tests and dev."
  @spec report([String.t()], [integer()]) :: map()
  def report(answers, reading_ids \\ []) do
    %{
      "summary" => "They described their own use of AI with some specific examples.",
      "overall" =>
        "They gave concrete examples of personal use and fewer about leading others. The profile is uneven across the areas.",
      "areas" =>
        for {area, i} <- Enum.with_index(Rubric.areas()) do
          %{
            "area" => Atom.to_string(area),
            "level" => "developing",
            "confidence" => "medium",
            "description" => "They gave one example in this area.",
            "confidence_in_words" => "Based on one example.",
            "quotes" => quote_from(answers, i),
            "strong_answer" => "A specific instance with what changed and how it was measured.",
            "shortfall" => "The example lacked a measured outcome."
          }
        end,
      "your_report" => %{
        "summary" => "You described your own use of AI with some specific examples.",
        "overall" =>
          "You gave concrete examples of personal use and fewer about leading others. Your profile is uneven across the areas.",
        "areas" =>
          Map.new(
            Rubric.areas(),
            &{Atom.to_string(&1),
             %{
               "description" => "You gave one example in this area.",
               "confidence_in_words" => "Based on one example."
             }}
          ),
        "strengths" => [
          %{
            "point" => "You use AI in your own work.",
            "evidence" => "You described a recent task."
          }
        ],
        "main_gap" => "You said little about how you bring your team along.",
        "next_steps" => %{
          "first_two_weeks" => %{
            "step" => "Pick one recurring team task and try AI on it with a colleague.",
            "how_you_will_know" => "The colleague keeps using it without being asked."
          },
          "later" => ["Measure the time saved on that task over a month."]
        }
      },
      "reading_picks" =>
        Enum.map(reading_ids, &%{"id" => &1, "why" => "It picks up where your answers left off."}),
      "assessor_next_steps" => ["Ask how they would bring their team along."],
      "follow_up_questions" => [
        %{
          "question" => "What would you change about the initiative you described?",
          "listen_for" => "A specific change and why."
        },
        %{
          "question" => "How do you check an output that matters?",
          "listen_for" => "A habit, not a principle."
        }
      ],
      "manipulation_attempted" => false
    }
  end

  defp quote_from([], _i), do: []

  defp quote_from(answers, i) do
    answer = Enum.at(answers, rem(i, length(answers)))
    [answer |> String.split() |> Enum.take(8) |> Enum.join(" ")]
  end

  defp ok(data) do
    content = Jason.encode!(data)

    {:ok,
     %{content: content, data: data, usage: %{total_tokens: div(byte_size(content), 4) + 500}}}
  end

  defp user_text(%{messages: messages}) do
    messages |> Enum.filter(&(&1.role == "user")) |> Enum.map_join("\n", & &1.content)
  end

  defp count(text, regex), do: length(Regex.scan(regex, text))

  defp all_areas, do: Enum.map(Rubric.areas(), &Atom.to_string/1)
end
