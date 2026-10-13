defmodule AiInPracticeWeb.PageController do
  use AiInPracticeWeb, :controller

  # The date the privacy notice and terms last changed in substance. Change
  # it with the wording.
  @legal_updated "13 October 2026"

  def home(conn, _params) do
    render(conn, :home, page_title: "AI in Practice")
  end

  def privacy(conn, _params) do
    render(conn, :privacy, page_title: "Privacy notice", updated: @legal_updated)
  end

  def terms(conn, _params) do
    render(conn, :terms, page_title: "Terms", updated: @legal_updated)
  end
end
