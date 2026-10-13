defmodule AiInPractice.Eval.Summary do
  @moduledoc """
  The harness summary as Markdown: one table per persona (levels per area
  across runs against the persona's true level), the fairness pairs, then
  validation, latency, cost and the calls by purpose.
  """

  alias AiInPractice.Rubric

  @doc "The summary as Markdown. `settings` are shown at the top (model, runs, caps)."
  @spec markdown(map(), map()) :: String.t()
  def markdown(summary, settings) do
    [
      "# Persona evaluation\n\n",
      Enum.map_join(settings, "\n", fn {k, v} -> "- #{k}: #{v}" end),
      "\n\n## Totals\n",
      totals(summary),
      "\n## Personas\n",
      Enum.map_join(summary.personas, "\n", &persona/1),
      pairs(summary.pairs),
      "\n## Calls by purpose\n",
      calls(summary.calls)
    ]
    |> IO.iodata_to_binary()
  end

  defp totals(s) do
    t = s.totals

    """
    - Runs: #{t.runs}; reports written: #{t.reports}; valid on the first attempt: #{t.first_pass}
    - Model calls: #{t.calls}; spend: $#{money(t.cost)}#{if t.tripped, do: " (a cap was reached; later runs were skipped)", else: ""}
    - Cost per completed session: #{if s.cost_per_report, do: "$" <> money(s.cost_per_report), else: "n/a"}
    - Next question (ms): #{stats(s.latency.question_ms)}
    - Report after closing (ms): #{stats(s.latency.report_ms)}
    - Report rejections (each regenerated once): #{rejections(s.rejections)}
    - Questions: #{questions(s.questions)}
    """
  end

  defp persona(p) do
    header = """
    ### #{p.persona} (#{p.role_group})

    Reports #{p.reports}/#{p.runs}, first-attempt valid #{p.first_pass}#{failures(p.failures)}#{manipulation(p.manipulation)}

    Questions: #{questions(p.questions)}

    | Area | True | Levels by run | Spread | Bias | Description overlap |
    |---|---|---|---|---|---|
    """

    rows =
      Enum.map_join(p.areas, "\n", fn a ->
        "| #{Rubric.area_name(a.area)} | #{a.truth} | #{Enum.join(a.levels, ", ")} | " <>
          "#{num(a.spread)} | #{signed(a.bias)} | #{num(a.description_overlap)} |"
      end)

    header <> rows <> "\n"
  end

  defp rejections(map) when map_size(map) == 0, do: "none"
  defp rejections(map), do: Enum.map_join(map, ", ", fn {k, n} -> "#{k} (#{n})" end)

  defp questions(%{runs: 0}), do: "n/a"

  defp questions(q) do
    "#{num(q.questions_per_run)} per run, #{q.follow_ups} follow-ups " <>
      "(#{q.consecutive_follow_ups} back to back), #{pct(q.grounded)} build on earlier answers, " <>
      "#{q.near_script} near-verbatim guidance questions, #{q.level_leaks} naming a level or score"
  end

  defp pct(nil), do: "n/a"
  defp pct(x), do: "#{round(x * 100)}%"

  defp failures([]), do: ""
  defp failures(list), do: "; failed: #{list |> Enum.frequencies() |> inspect()}"

  defp manipulation(%{expected: true, flagged: n}), do: "; manipulation note: #{n} (expected)"
  defp manipulation(%{flagged: 0}), do: ""
  defp manipulation(%{flagged: n}), do: "; manipulation note: #{n} (not expected)"

  defp pairs([]), do: ""

  defp pairs(pairs) do
    "\n## Fairness pairs\n\nShift is the second persona's mean level rank minus the first's.\n\n" <>
      Enum.map_join(pairs, "\n", fn %{personas: {a, b}, areas: areas} ->
        "### #{a} vs #{b}\n\n| Area | Modal levels | Shift |\n|---|---|---|\n" <>
          Enum.map_join(areas, "\n", fn x ->
            {ma, mb} = x.modal
            "| #{Rubric.area_name(x.area)} | #{ma} / #{mb} | #{signed(x.shift)} |"
          end) <> "\n"
      end)
  end

  defp calls(calls) do
    "| Purpose | Calls | Errors | ms (p50/p95/max) | Tokens | Spend |\n|---|---|---|---|---|---|\n" <>
      Enum.map_join(calls, "\n", fn {purpose, c} ->
        "| #{purpose} | #{c.count} | #{if c.errors == %{}, do: "none", else: inspect(c.errors)} | " <>
          "#{stats(c.ms)} | #{c.tokens} | $#{money(c.cost)} |"
      end) <> "\n"
  end

  defp stats(nil), do: "n/a"
  defp stats(%{p50: a, p95: b, max: c}), do: "#{a} / #{b} / #{c}"

  defp money(x), do: :erlang.float_to_binary(x / 1, decimals: 4)

  defp num(nil), do: "n/a"
  defp num(x) when is_integer(x), do: Integer.to_string(x)
  defp num(x), do: :erlang.float_to_binary(x, decimals: 2)

  defp signed(nil), do: "n/a"
  defp signed(x) when x > 0, do: "+" <> num(x / 1)
  defp signed(x), do: num(x / 1)
end
