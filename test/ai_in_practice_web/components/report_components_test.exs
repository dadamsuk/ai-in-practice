defmodule AiInPracticeWeb.ReportComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AiInPracticeWeb.ReportComponents

  defp render_blocks(blocks), do: render_component(&ReportComponents.blocks/1, blocks: blocks)

  test "sections, areas, labels and quotes each get their own markup (#804)" do
    html =
      render_blocks([
        {:statement, "A conversation starter."},
        {:h2, "Summary"},
        {:p, "You use AI daily."},
        {:h3, "Personal use"},
        {:quote, "I checked every figure."},
        {:labelled, "how sure this is", "Based on one example."},
        {:list, ["One.", "Two."]}
      ])

    doc = LazyHTML.from_fragment(html)

    assert doc |> LazyHTML.query(".report-body > h3.report-section") |> LazyHTML.text() ==
             "Summary"

    assert doc |> LazyHTML.query(".report-body > h4.report-area") |> LazyHTML.text() ==
             "Personal use"

    assert doc |> LazyHTML.query("p.statement strong") |> LazyHTML.text() ==
             "A conversation starter."

    assert doc |> LazyHTML.query("blockquote") |> LazyHTML.text() == "I checked every figure."

    # A label and its text side by side: two children, no line break.
    label = LazyHTML.query(doc, "div.labelled > span.labelled-label.mono.quiet")
    assert LazyHTML.text(label) == "how sure this is"
    assert doc |> LazyHTML.query("div.labelled > p") |> LazyHTML.text() == "Based on one example."
    assert doc |> LazyHTML.query("div.labelled br") |> Enum.count() == 0

    assert doc |> LazyHTML.query("ul > li") |> Enum.count() == 2
  end

  test "text is escaped, never read as markup" do
    html = render_blocks([{:labelled, "<b>label</b>", "<script>x</script>"}])
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "no blocks is an empty body" do
    doc = LazyHTML.from_fragment(render_blocks([]))
    assert doc |> LazyHTML.query(".report-body") |> Enum.count() == 1
    assert doc |> LazyHTML.query(".report-body *") |> Enum.count() == 0
  end
end
