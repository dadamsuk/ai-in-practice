defmodule AiInPracticeWeb.Admin.PageController do
  use AiInPracticeWeb, :admin_controller

  def home(conn, _params) do
    render(conn, :home, page_title: "Admin")
  end
end
