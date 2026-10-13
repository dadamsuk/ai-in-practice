defmodule AiInPracticeWeb.AssessmentController do
  @moduledoc """
  Where an assessment link lands. For now this only says whether the link
  can be used; the start screen and conversation replace it (epic 4).
  Opening this page never uses the link up.
  """
  use AiInPracticeWeb, :controller

  alias AiInPractice.Links

  def show(conn, %{"token" => token}) do
    case Links.begin_session(token) do
      {:ok, _link} ->
        render(conn, :ready, page_title: "Your link")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:unusable, reason: :not_found, page_title: "Link")

      {:error, reason} ->
        conn |> put_status(:gone) |> render(:unusable, reason: reason, page_title: "Link")
    end
  end
end
