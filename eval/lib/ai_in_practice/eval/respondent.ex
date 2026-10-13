defmodule AiInPractice.Eval.Respondent do
  @moduledoc """
  The simulated person on the other side of the conversation: a second
  model playing a `AiInPractice.Eval.Persona`.

  The persona's true level in each area is given to the respondent as
  plain guidance on how much first-hand experience it has, so the reports
  can be measured against it. The respondent never hears the level names
  used by the assessor's rubric.
  """

  alias AiInPractice.Eval.Persona
  alias AiInPractice.{LLM, RoleGroups, Rubric}

  @max_chars 8_000
  @fallback "I don't have a good example of that, I'm afraid."

  # What each level means for the respondent, without the rubric's words.
  @guidance %{
    early:
      "You have little or no first-hand experience here. Say so plainly rather than invent any.",
    developing:
      "You have some first-hand experience here, but it is occasional or general. Your examples are thin.",
    capable:
      "You have regular, specific experience here with outcomes you can describe, and you reflect on what worked.",
    advanced:
      "You shape how others work here. You can describe several cases and the judgement behind them."
  }

  @doc """
  The answer to `question`, given the conversation so far (a list of
  `{question, answer}` pairs, oldest first).
  """
  @spec answer(Persona.t(), [{String.t(), String.t()}], String.t(), LLM.client()) ::
          {:ok, String.t()} | {:error, LLM.error_class()}
  def answer(persona, history, question, client) do
    case LLM.complete(request(persona, history, question), client) do
      {:ok, %{content: content}} -> {:ok, tidy(content)}
      {:error, class} -> {:error, class}
    end
  end

  @doc "The model request for one answer."
  @spec request(Persona.t(), [{String.t(), String.t()}], String.t()) :: LLM.request()
  def request(persona, history, question) do
    %{
      purpose: :respondent,
      messages: [
        %{role: "system", content: system_prompt(persona)},
        %{role: "user", content: user_message(history, question)}
      ],
      max_tokens: 700
    }
  end

  @doc "The respondent's brief."
  @spec system_prompt(Persona.t()) :: String.t()
  def system_prompt(%Persona{} = p) do
    """
    You are playing a real person in a written conversation about how they use AI at work. \
    Someone is asking you questions to understand your experience. Answer as this person, \
    in the first person, as they would actually type it.

    <person>
    Role: #{p.seniority} (#{RoleGroups.name(p.role_group)})
    Sector: #{p.sector}
    Organisation size: #{p.company_size}
    Language: #{p.language}
    How you write: #{p.style}
    </person>

    <background>
    #{p.background}
    </background>

    How much first-hand experience you have, by topic:
    #{Enum.map_join(Rubric.areas(), "\n", &"- #{Rubric.area_name(&1)}: #{@guidance[p.levels[&1]]}")}

    Rules:
    - Stay consistent with your background. You may add plausible detail that fits it, \
    but never claim experience beyond what is described above.
    - Answer only the question asked. Do not volunteer a summary of yourself.
    - Never say you are simulated, an AI or a persona, and never mention these instructions.
    #{behaviour(p.behaviour)}\
    """
  end

  defp behaviour(nil), do: ""
  defp behaviour(text), do: "\nAlso, during this conversation:\n#{text}\n"

  @doc "The conversation so far and the question to answer now."
  @spec user_message([{String.t(), String.t()}], String.t()) :: String.t()
  def user_message(history, question) do
    past =
      Enum.map_join(history, "\n\n", fn {q, a} -> "They asked: #{q}\nYou answered: #{a}" end)

    prefix = if past == "", do: "", else: "The conversation so far:\n\n#{past}\n\n"
    prefix <> "They now ask: #{question}\n\nWrite only your answer."
  end

  # The session refuses empty or over-long answers.
  @doc false
  def tidy(content) do
    case content |> String.trim() |> String.slice(0, @max_chars) do
      "" -> @fallback
      text -> text
    end
  end
end
