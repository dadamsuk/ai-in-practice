defmodule AiInPracticeWeb.AdminRouter do
  @moduledoc """
  Routes for the admin endpoint only. Everything lives under `/admin`, so a
  test can check that none of these paths answer on the public endpoint.
  """
  use AiInPracticeWeb, :router

  alias AiInPracticeWeb.Plugs.SecurityHeaders

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AiInPracticeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => SecurityHeaders.csp()}
    plug SecurityHeaders, private: true
  end

  scope "/admin", AiInPracticeWeb.Admin do
    pipe_through :browser

    get "/", PageController, :home
  end
end
