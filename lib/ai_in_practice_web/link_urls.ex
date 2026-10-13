defmodule AiInPracticeWeb.LinkURLs do
  @moduledoc """
  Full public URLs for link tokens, for the admin pages, the admin CLI and
  the recruiter page. They point at the public endpoint whichever endpoint
  builds them.
  """
  use Phoenix.VerifiedRoutes,
    endpoint: AiInPracticeWeb.Endpoint,
    router: AiInPracticeWeb.Router

  @doc "The recruiter page for a recruiter-mode token."
  @spec recruiter_url(String.t()) :: String.t()
  def recruiter_url(token), do: url(~p"/r/#{token}")

  @doc "The assessment start page for a candidate or individual token."
  @spec assessment_url(String.t()) :: String.t()
  def assessment_url(token), do: url(~p"/a/#{token}")
end
