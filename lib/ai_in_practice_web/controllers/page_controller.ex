defmodule AiInPracticeWeb.PageController do
  use AiInPracticeWeb, :controller

  def home(conn, _params) do
    render(conn, :home, page_title: "AI in Practice")
  end
end
