defmodule AiInPracticeWeb.ReportHTML do
  use AiInPracticeWeb, :html

  def gone(assigns) do
    ~H"""
    <Layouts.app flash={%{}}>
      <h1>This report is no longer available</h1>
      <p class="lede">Reports are held only while their page is open, for an hour at most.</p>
      <p>
        If the page with your reports is still open, download them from there. If it has been closed, they cannot be recovered: nothing is kept.
      </p>
    </Layouts.app>
    """
  end
end
