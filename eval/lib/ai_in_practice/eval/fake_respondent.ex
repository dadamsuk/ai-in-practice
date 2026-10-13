defmodule AiInPractice.Eval.FakeRespondent do
  @moduledoc """
  A free, deterministic respondent for trying the harness and for tests
  (`mix eval.personas --fake`): it answers every question with the first
  sentence of the persona's background, numbered so no two answers match.
  Options: `:fail_after` (`{n, class}`) fails every answer after `n`.
  """

  @behaviour AiInPractice.LLM

  @impl true
  def request(%{messages: [%{content: system}, %{content: user}]}, opts) do
    answered = length(Regex.scan(~r/^You answered: /m, user))

    case Keyword.get(opts, :fail_after) do
      {n, class} when answered >= n ->
        {:error, class}

      _ ->
        content = "#{first_sentence(system)} (answer #{answered + 1})"
        {:ok, %{content: content, data: nil, usage: %{total_tokens: 100, cost: 0.0}}}
    end
  end

  defp first_sentence(system) do
    case Regex.run(~r{<background>\s*(.*?[.!?])}s, system) do
      [_, sentence] -> String.replace(sentence, ~r/\s+/, " ")
      nil -> "I have used it a little."
    end
  end
end
