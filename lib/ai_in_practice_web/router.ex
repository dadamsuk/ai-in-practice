defmodule AiInPracticeWeb.Router do
  @moduledoc """
  The public router. Admin routes are never defined here: they live on
  `AiInPracticeWeb.AdminRouter`, served by a separate listener.
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
    plug SecurityHeaders
  end

  # For assessment pages, report downloads and any URL carrying a link token:
  # never cached, never indexed.
  pipeline :private do
    plug SecurityHeaders, private: true
  end

  scope "/", AiInPracticeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Every route here carries a link token in its path.
  scope "/", AiInPracticeWeb do
    pipe_through [:browser, :private]

    get "/a/:token", AssessmentController, :show

    live_session :recruiter do
      live "/r/:token", RecruiterLive
    end
  end
end
