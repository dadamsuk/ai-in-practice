defmodule AiInPracticeWeb.AssessmentHTML do
  use AiInPracticeWeb, :html

  embed_templates "assessment_html/*"

  @doc """
  The one dead end for a link that cannot be opened: unknown, withdrawn,
  used or completed all look the same, so the page says nothing about
  whether a link exists or what happened to it (#701).
  """
  def dead_end(assigns) do
    ~H"""
    <div id="dead-end">
      <h1>This link cannot be opened</h1>
      <p class="lede">Each link works once, and links can be withdrawn.</p>
      <p>
        Check that you copied the whole address. If it still does not open, ask the person who sent it to you for a new one.
      </p>
    </div>
    """
  end
end
