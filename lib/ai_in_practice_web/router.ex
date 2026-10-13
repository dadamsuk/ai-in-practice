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

  pipeline :usable_link do
    plug AiInPracticeWeb.Plugs.UsableLink
  end

  # Report downloads: a PDF from a live session, never cached.
  pipeline :download do
    plug :accepts, ["html", "pdf"]
    plug :put_secure_browser_headers, %{"content-security-policy" => SecurityHeaders.csp()}
    plug SecurityHeaders, private: true
  end

  pipeline :public_json do
    plug :accepts, ["json"]
  end

  scope "/", AiInPracticeWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
  end

  # The public keys that sign assessor reports, for anyone verifying one.
  scope "/.well-known/ai-in-practice", AiInPracticeWeb do
    pipe_through :public_json

    get "/signing-keys.json", SigningKeyController, :index
  end

  # The check page: anyone can upload an assessor report and see its signed
  # content, which is a report, so never cached or indexed.
  scope "/", AiInPracticeWeb do
    pipe_through [:browser, :private]

    get "/check", CheckController, :new
    post "/check", CheckController, :create
  end

  # Every route here carries a link token in its path.
  scope "/", AiInPracticeWeb do
    pipe_through [:browser, :private]

    live_session :recruiter do
      live "/r/:token", RecruiterLive
    end
  end

  # The candidate journey, for a link that can be started; a 404 dead end
  # for any other.
  scope "/", AiInPracticeWeb do
    pipe_through [:browser, :private, :usable_link]

    live_session :assessment do
      live "/a/:token", AssessmentLive
    end
  end

  # The path carries the session id, which is as secret as a link token.
  # No CSRF check: the beacon that ends a session cannot send a token, and
  # the id is the capability.
  scope "/", AiInPracticeWeb do
    pipe_through :download

    get "/reports/:session/:audience", ReportController, :show
    post "/sessions/:session/end", SessionController, :stop
  end
end
