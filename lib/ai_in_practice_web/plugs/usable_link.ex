defmodule AiInPracticeWeb.Plugs.UsableLink do
  @moduledoc """
  In front of `/a/:token`: a link that can be started goes on to the
  candidate journey (`AiInPracticeWeb.AssessmentLive`); anything else gets
  one dead end with a 404, the same for an unknown, withdrawn, used or
  completed link, so the response says nothing about the link. Checking
  never uses the link up.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [put_view: 2, render: 3]

  alias AiInPractice.Links

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_params: %{"token" => token}} = conn, _opts) do
    case Links.begin_session(token) do
      {:ok, _link} -> conn
      {:error, _reason} -> dead_end(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp dead_end(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: AiInPracticeWeb.AssessmentHTML)
    |> render(:unusable, page_title: "Link")
    |> halt()
  end
end
