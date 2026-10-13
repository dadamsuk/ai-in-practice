defmodule AiInPracticeWeb.ReportControllerTest do
  # Not async: the sessions under test run in the shared supervisor.
  use AiInPracticeWeb.ConnCase, async: false

  import AiInPractice.SessionHelpers

  alias AiInPractice.{Assessment, LLMScript}
  alias AiInPractice.Reports.{PDF, Signing}

  @moduletag :capture_log

  @meta %{
    link_id: 1,
    link_kind: :candidate,
    role_group: :finance,
    mode: :text,
    date: ~D[2026-10-13]
  }

  defp finished_session do
    {client, _} = LLMScript.client([LLMScript.turn("Q1"), LLMScript.turn("", [], close: true)])
    {:ok, id} = Assessment.start(:finance, llm: client, reading: [], meta: @meta)
    assert_event(id, {:question, _})
    :ok = Assessment.answer(id, "I used AI to draft the quarterly pricing paper.")
    assert_event(id, {:report, _})
    id
  end

  test "both reports download as PDFs, never cached", %{conn: conn} do
    id = finished_session()

    for {audience, filename} <- [
          {"candidate", "ai-in-practice-your-report.pdf"},
          {"assessor", "ai-in-practice-assessor-report.pdf"}
        ] do
      conn = get(build_conn(), ~p"/reports/#{id}/#{audience}")
      assert conn.status == 200
      assert conn.resp_body =~ ~r/\A%PDF-1\.\d/
      assert get_resp_header(conn, "content-type") == ["application/pdf"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ filename
    end

    assert conn
  end

  test "only the assessor PDF is signed, and it verifies against the published key", %{
    conn: conn
  } do
    id = finished_session()
    name = Signing.attachment_name()

    assessor = get(conn, ~p"/reports/#{id}/assessor").resp_body
    candidate = get(build_conn(), ~p"/reports/#{id}/candidate").resp_body

    assert PDF.attachment(candidate, name) == :error
    assert {:ok, envelope} = PDF.attachment(assessor, name)

    %{"keys" => [published]} =
      build_conn() |> get("/.well-known/ai-in-practice/signing-keys.json") |> json_response(200)

    {:ok, keyring} = Signing.parse(private_key: Base.encode64(:crypto.strong_rand_bytes(32)))

    public = %{
      keyring
      | current: %{
          kid: published["kid"],
          public_key: Base.decode64!(published["public_key"]),
          private_key: nil
        }
    }

    assert {:ok, payload} = Signing.verify(envelope, public)
    assert payload["role_group"] == "finance"
    assert payload["link"] == "from a recruiter"
  end

  test "downloads fail once the session has gone", %{conn: conn} do
    id = finished_session()
    Assessment.stop(id)
    assert gone?(id)

    conn = get(conn, ~p"/reports/#{id}/candidate")
    assert html_response(conn, 404) =~ "This report is no longer available"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "nothing to download before the report is written", %{conn: conn} do
    {client, _} = LLMScript.client([LLMScript.turn("Q1")])
    {:ok, id} = Assessment.start(:finance, llm: client, reading: [], meta: @meta)
    assert_event(id, {:question, _})

    assert conn |> get(~p"/reports/#{id}/candidate") |> html_response(404)
  end

  test "an unknown session or audience is a 404", %{conn: conn} do
    id = finished_session()
    assert conn |> get(~p"/reports/#{id}/transcript") |> html_response(404)

    assert build_conn()
           |> get(~p"/reports/AAAAAAAAAAAAAAAAAAAAAAAA/candidate")
           |> html_response(404)
  end
end
