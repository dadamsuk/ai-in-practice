defmodule AiInPracticeWeb.CheckHTML do
  @moduledoc """
  The check page's screens. The wording is careful (PRD §9): a match says
  the report is genuine and unedited, never who took part, and the page
  never says "verified".
  """
  use AiInPracticeWeb, :html

  import AiInPracticeWeb.ReportComponents, only: [blocks: 1]

  alias AiInPractice.Reports.{Content, Payload}
  alias AiInPracticeWeb.Plugs.CheckUpload

  embed_templates "check_html/*"

  @doc "The largest PDF the page reads, in whole megabytes."
  def limit_mb, do: div(CheckUpload.limit(), 1_000_000)

  @doc "Whether the page knows how to lay out this payload."
  def known_format?(payload), do: payload["format"] == Payload.format()

  @doc "The signed payload as indented JSON, for a format this page does not know."
  def raw_json(payload), do: Jason.encode!(payload, pretty: true)

  @doc "The versions a payload was written with."
  def versions(payload) do
    v = payload["versions"] || %{}
    "code #{v["code"]} · rubric v#{v["rubric"]} · model #{v["model"]}"
  end

  defdelegate signed_header(payload), to: Content
  defdelegate signed_blocks(payload), to: Content

  @doc "Why a form submission was refused."
  def error_message(:missing), do: "Choose a PDF to check."
  def error_message(:not_pdf), do: "That file is not a PDF. Choose the assessor report PDF."

  def error_message(:too_large),
    do:
      "That file is larger than #{limit_mb()} MB, far bigger than any assessor report. Choose the assessor report PDF."
end
