defmodule AiInPracticeWeb.VocabularyTest do
  # PRD §1, §4 and the rubric's "Conversation design": what candidates and
  # recruiters read never says "interview" or "verified", has no scores,
  # pass marks or tests of the person, and no product language.
  use AiInPracticeWeb.ConnCase, async: true

  alias AiInPractice.VocabularyGuard, as: Guard

  # Everything a candidate or recruiter can read. Admin pages are DSC's own
  # and are not covered.
  @copy_sources Enum.sort(
                  Path.wildcard("lib/ai_in_practice_web/controllers/**/*.heex") ++
                    Path.wildcard("lib/ai_in_practice_web/controllers/*_html.ex") ++
                    Path.wildcard("lib/ai_in_practice_web/components/**/*.{ex,heex}") ++
                    [
                      "lib/ai_in_practice_web/live/assessment_live.ex",
                      "lib/ai_in_practice_web/live/recruiter_live.ex",
                      "lib/ai_in_practice/reports/content.ex",
                      "lib/ai_in_practice/role_groups.ex",
                      "priv/reports/report.typ"
                    ]
                )

  for path <- @copy_sources, do: @external_resource(path)

  test "candidate- and recruiter-facing copy uses none of the banned terms" do
    for path <- [
          "lib/ai_in_practice_web/controllers/page_html/privacy.html.heex",
          "lib/ai_in_practice_web/controllers/page_html/terms.html.heex",
          "lib/ai_in_practice_web/live/assessment_live.ex"
        ] do
      assert path in @copy_sources
    end

    found =
      for path <- @copy_sources,
          term <- path |> Guard.copy() |> Guard.banned(),
          do: "#{path}: #{term}"

    assert found == []
  end

  test "the rendered home, privacy and terms pages use none of the banned terms" do
    for path <- [~p"/", ~p"/privacy", ~p"/terms"] do
      text =
        build_conn()
        |> get(path)
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("main")
        |> LazyHTML.text()

      assert String.length(text) > 200
      assert Guard.banned(text) == [], "banned term on #{path}"
    end
  end

  describe "the guard itself" do
    test "catches a word planted in a template, and nothing in its markup or code" do
      copy = Guard.copy("test/support/fixtures/vocabulary/planted.html.heex")

      assert Guard.banned(copy) == ["interview", "score"]
      refute copy =~ "failed"
      refute copy =~ "data-score"
    end

    test "allows plain statements of what the framework is not" do
      assert Guard.banned("It gives no score. There are no scores and no pass mark.") == []
      assert Guard.banned("Your answers pass through Cloudflare.") == []
    end

    test "flags each kind of banned term, in the order it appears" do
      assert Guard.banned("A verified test with a pass mark you passed.") ==
               ["verified", "test", "pass mark", "passed"]

      assert Guard.banned("Sign up for a free trial: see our pricing plans.") ==
               ["Sign up", "free trial", "pricing", "plans"]

      assert Guard.banned("You failed the Interview and got a low score.") ==
               ["failed", "Interview", "score"]
    end

    test "reads strings, not documentation or comments, from Elixir modules" do
      dir = Path.join(System.tmp_dir!(), "vocab-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "copy.ex")

      File.write!(path, ~S'''
      defmodule Planted do
        @moduledoc """
        Says interview in its docs, which nobody using the site reads.
        """
        # A comment about a failed test.
        def failed(socket), do: socket

        def title, do: "Your verified report"

        def render(assigns) do
          ~H"""
          <p class={@failed}>Plain words, then a score.</p>
          """
        end
      end
      ''')

      assert path |> Guard.copy() |> Guard.banned() == ["score", "verified"]
    end

    test "reads the strings in Typst code" do
      dir = Path.join(System.tmp_dir!(), "vocab-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "report.typ")
      File.write!(path, ~S|#let verify_at = data.x
#text("Interview notes")|)

      assert path |> Guard.copy() |> Guard.banned() == ["Interview"]
    end
  end
end
