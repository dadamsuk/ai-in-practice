defmodule AiInPracticeWeb.CheckController do
  @moduledoc """
  The check page, `/check` (PRD §9, §15 v2; #720). Anyone can upload an
  assessor report PDF; the page checks its embedded signature
  (`AiInPractice.Reports.Check`) and shows the signed content in full, so
  an edit to the visible pages shows up as a difference.

  The PDF arrives in memory (`AiInPracticeWeb.Plugs.CheckUpload`), is
  checked and is dropped with the request: it is never written anywhere.
  The path avoids "verify", which the PRD's vocabulary rules out.
  """
  use AiInPracticeWeb, :controller

  alias AiInPractice.Reports.Check

  def new(conn, _params), do: render_form(conn, :ok, nil)

  def create(conn, _params) do
    upload = conn.private[:check_upload] || {:error, :missing}
    # Not carried any further than it needs to be, for instance into a
    # crash report.
    conn = put_private(conn, :check_upload, nil)

    case upload do
      {:ok, pdf} -> show(conn, Check.check(pdf))
      {:error, :too_large} -> render_form(conn, :request_entity_too_large, :too_large)
      {:error, :missing} -> render_form(conn, :unprocessable_entity, :missing)
    end
  end

  defp show(conn, {:ok, %{payload: payload, kid: kid}}),
    do: render(conn, :match, page_title: "Report checked", payload: payload, kid: kid)

  defp show(conn, {:error, :not_pdf}), do: render_form(conn, :unprocessable_entity, :not_pdf)

  defp show(conn, {:error, reason}),
    do: render(conn, :no_match, page_title: "Report checked", reason: reason)

  defp render_form(conn, status, error) do
    conn
    |> put_status(status)
    |> render(:new, page_title: "Check an assessor report", error: error)
  end
end
