defmodule AiInPracticeWeb.ReportController do
  @moduledoc """
  Report downloads, `/reports/:session/:audience` (PRD §7 step 5). The PDF
  is made from the report held by the live session process and nothing
  else: once the session has gone (the page was closed, or the hour is up)
  there is nothing to download. Served through the `:private` pipeline,
  so never cached.
  """
  use AiInPracticeWeb, :controller

  alias AiInPractice.Assessment
  alias AiInPractice.Reports.PDF

  @audiences %{"candidate" => :candidate, "assessor" => :assessor}

  def show(conn, %{"session" => id, "audience" => audience}) do
    with {:ok, audience} <- Map.fetch(@audiences, audience),
         {:ok, report, meta} <- Assessment.download(id) do
      send_download(conn, {:binary, PDF.render(audience, report, meta)},
        filename: PDF.filename(audience),
        content_type: "application/pdf"
      )
    else
      _ -> gone(conn)
    end
  end

  defp gone(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: AiInPracticeWeb.ReportHTML)
    |> put_root_layout(html: {AiInPracticeWeb.Layouts, :root})
    |> render(:gone, page_title: "Reports")
  end
end
