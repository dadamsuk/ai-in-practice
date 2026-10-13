defmodule AiInPractice.VocabularyGuard do
  @moduledoc """
  The PRD's vocabulary for anything a candidate or recruiter reads (PRD §1,
  §4; rubric "Conversation design"): never "interview", never "verified", no
  scores, pass marks or tests of the person, and no product language.

  `copy/1` pulls the words a person could see out of a template or module
  (HEEx text and the strings in Elixir and Typst code), and `banned/1`
  lists the banned terms in a piece of text. Plain statements of what the
  framework is not ("no scores", "no pass mark") are allowed.
  """

  @banned [
    ~r/\binterview(s|ed|er|ers|ing)?\b/i,
    ~r/\bverif(y|ied|ies|ication)\b/i,
    ~r/\bscor(e|es|ed|ing)\b/i,
    ~r/\bpass(ed)? mark\b|\bpassed\b|\bpass\s*(\/|or)\s*fail\b/i,
    ~r/\bfail(s|ed|ure)?\b/i,
    ~r/\btest(s|ed|ing)?\b/i,
    ~r/\bsign[- ]?up\b|\bsubscri(be|ption)\b|\bpric(e|es|ing)\b|\bfree trial\b/i,
    ~r/\b(plan|plans|upgrade|purchase|customer|customers)\b/i
  ]

  @allowed ~r/\bno (scores?|pass mark)\b/i

  @doc "The banned terms in `text`, as they appear, in order."
  @spec banned(String.t()) :: [String.t()]
  def banned(text) do
    text = Regex.replace(@allowed, text, " ")

    @banned
    |> Enum.flat_map(&Regex.scan(&1, text, return: :index))
    |> Enum.map(fn [{start, len} | _] -> {start, binary_part(text, start, len)} end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  @doc "The words a person could see in the file at `path`."
  @spec copy(Path.t()) :: String.t()
  def copy(path) do
    source = File.read!(path)

    case Path.extname(path) do
      ".heex" -> heex_text(source)
      ".ex" -> elixir_copy(source)
      ".typ" -> source |> strings() |> Enum.join("\n")
    end
  end

  # HEEx: drop scripts, EEx tags and HTML tags (with their attributes), and
  # keep the text and the strings inside `{...}` expressions.
  defp heex_text(source) do
    source = Regex.replace(~r/<script.*?<\/script>/s, source, " ")
    source = Regex.replace(~r/<%.*?%>/s, source, " ")
    source = Regex.replace(~r/<[^>]*>/s, source, " ")

    Regex.replace(~r/\{([^{}]*)\}/s, source, fn _, expr -> Enum.join(strings(expr), " ") end)
  end

  # Elixir: every ~H template, plus the string literals outside them, leaving
  # out documentation and comments, which nobody using the site reads.
  defp elixir_copy(source) do
    source = Regex.replace(~r/@(module)?doc\s+(""".*?"""|"(\\.|[^"\\])*"|false)/s, source, " ")
    source = Regex.replace(~r/^\s*#.*$/m, source, " ")
    templates = Regex.scan(~r/~H"""(.*?)"""/s, source, capture: :all_but_first)
    code = Regex.replace(~r/~H""".*?"""/s, source, " ")

    Enum.map_join(templates, "\n", fn [t] -> heex_text(t) end) <>
      "\n" <> Enum.join(strings(code), "\n")
  end

  defp strings(code) do
    ~r/"((\\.|[^"\\])*)"/s
    |> Regex.scan(code, capture: :all_but_first)
    |> Enum.map(fn [s | _] -> s end)
  end
end
