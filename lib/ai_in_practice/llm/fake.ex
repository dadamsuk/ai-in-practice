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

    data =
      if asked >= limit do
        %{"question" => "", "kind" => "main", "covered_areas" => all_areas(), "close" => true}
      else
        {_area, question} = Enum.at(@bank, rem(asked, length(@bank)))

        covered =
          @bank |> Enum.take(min(asked, length(@bank))) |> Enum.map(&Atom.to_string(elem(&1, 0)))

        %{"question" => question, "kind" => "main", "covered_areas" => covered, "close" => false}
      end

    ok(data)
  end

  defp default(%{purpose: :report} = request, _opts) do
    text = user_text(request)
    answers = for [_, a] <- Regex.scan(~r{<answer>\n(.*?)\n</answer>}s, text), do: a
    reading = for [_, id] <- Regex.scan(~r/<reading id="(\d+)">/, text), do: String.to_integer(id)
    ok(report(answers, Enum.take(reading, 2)))
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
      "strengths" => [
        %{"point" => "You use AI in your own work.", "evidence" => "You described a recent task."}
      ],
      "main_gap" => "You said little about how you bring your team along.",
      "next_steps" => %{
        "first_two_weeks" => %{
          "step" => "Pick one recurring team task and try AI on it with a colleague.",
          "how_you_will_know" => "The colleague keeps using it without being asked."
        },
        "later" => ["Measure the time saved on that task over a month."]
      },
      "reading_picks" => reading_ids,
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
