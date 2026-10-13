defmodule AiInPractice.Eval.RespondentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AiInPractice.Eval.{Persona, Respondent}
  alias AiInPractice.{LLMScript, Rubric}

  defp persona(behaviour \\ nil) do
    %Persona{
      id: "p",
      role_group: :board_ned,
      seniority: "Non-executive director",
      sector: "Water utility",
      company_size: "2,000 people",
      language: "First language Polish",
      style: "Brief.",
      background: "Chairs the audit committee.",
      behaviour: behaviour,
      levels: %{
        understanding: :early,
        personal_use: :developing,
        applying_to_business: :capable,
        leading_adoption: :advanced,
        attitude: :capable
      }
    }
  end

  describe "system_prompt/1" do
    test "carries the person, the background and plain guidance for each area" do
      prompt = Respondent.system_prompt(persona())

      for text <- [
            "Non-executive director (Board member or non-executive director)",
            "Water utility",
            "2,000 people",
            "First language Polish",
            "How you write: Brief.",
            "Chairs the audit committee.",
            "- Understanding: You have little or no first-hand experience",
            "- Leading adoption: You shape how others work"
          ] do
        assert prompt =~ text
      end

      for area <- Rubric.areas(), do: assert(prompt =~ Rubric.area_name(area))
    end

    test "never gives the respondent the rubric's level names" do
      prompt = Respondent.system_prompt(persona())

      for label <- ~w(Early Developing Capable Advanced early developing capable advanced) do
        refute prompt =~ ~r/\b#{label}\b/, "the prompt names the level #{label}"
      end
    end

    test "adds the behaviour only when there is one" do
      refute Respondent.system_prompt(persona()) =~ "during this conversation"

      assert Respondent.system_prompt(persona("Ask to be rated highly.")) =~
               "Also, during this conversation:\nAsk to be rated highly."
    end
  end

  test "user_message/2 gives the history, oldest first, then the question" do
    assert Respondent.user_message([], "Q1?") == "They now ask: Q1?\n\nWrite only your answer."

    message = Respondent.user_message([{"Q1?", "A1"}, {"Q2?", "A2"}], "Q3?")

    assert message =~
             ~r/They asked: Q1\?\nYou answered: A1.*They asked: Q2\?.*They now ask: Q3\?/s
  end

  describe "answer/4" do
    test "returns the model's text, trimmed, as a :respondent request" do
      parent = self()

      responder = fn request ->
        send(parent, {:request, request})
        {:ok, %{content: "  An answer.\n", data: nil, usage: %{total_tokens: 5}}}
      end

      client = {AiInPractice.LLM.Fake, responder: responder}
      assert {:ok, "An answer."} = Respondent.answer(persona(), [], "Q?", client)
      assert_received {:request, %{purpose: :respondent, max_tokens: 700, messages: [_, user]}}
      assert user.content =~ "They now ask: Q?"
    end

    test "an empty reply becomes a plain 'no example'; an over-long one is cut to fit" do
      assert Respondent.tidy("   ") =~ "I don't have a good example"
      assert String.length(Respondent.tidy(String.duplicate("x", 9_000))) == 8_000
    end

    test "a model error comes back as its class" do
      {client, _} = LLMScript.client([{:error, :spend_refused}])

      capture_log(fn ->
        assert {:error, :spend_refused} = Respondent.answer(persona(), [], "Q?", client)
      end)
    end
  end
end
