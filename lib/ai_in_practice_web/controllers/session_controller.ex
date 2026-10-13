defmodule AiInPracticeWeb.SessionController do
  @moduledoc """
  `POST /sessions/:session/end`, sent by the candidate page's
  `navigator.sendBeacon` as the page closes, so the session and everything
  it held go at once instead of after the reconnect grace period.

  The session id is the capability: whoever holds it can already download
  the reports, so letting them end the session gives nothing away. The
  answer is the same whether or not the session existed.
  """
  use AiInPracticeWeb, :controller

  alias AiInPractice.Assessment

  def stop(conn, %{"session" => id}) do
    :ok = Assessment.stop(id)
    send_resp(conn, :no_content, "")
  end
end
