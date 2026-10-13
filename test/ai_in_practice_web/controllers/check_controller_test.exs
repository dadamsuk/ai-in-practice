defmodule AiInPracticeWeb.CheckControllerTest do
  # The check page (#720). Uploads are real multipart bodies, so they go
  # through the endpoint's parsers as a browser's would. Not async: one test
  # looks for temporary files, and one captures every process's logs.
  use AiInPracticeWeb.ConnCase, async: false

  import AiInPractice.ReportFixtures

  alias AiInPractice.{GlobalLog, VocabularyGuard}
  alias AiInPractice.Reports.{Content, PDF, Signing}
  alias AiInPracticeWeb.Plugs.CheckUpload

  defp multipart(parts) do
    boundary = "checkboundary#{System.unique_integer([:positive])}"

    body =
      Enum.map_join(parts, fn
        {:file, name, filename, data} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"; " <>
            "filename=\"#{filename}\"\r\ncontent-type: application/pdf\r\n\r\n#{data}\r\n"

        {:field, name, value} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"

        {:unnamed, value} ->
          "--#{boundary}\r\ncontent-type: text/plain\r\n\r\n#{value}\r\n"
      end) <> "--#{boundary}--\r\n"

    {"multipart/form-data; boundary=#{boundary}", body}
  end

  defp upload(conn \\ build_conn(), parts) do
    {type, body} = multipart(parts)
    conn |> put_req_header("content-type", type) |> post(~p"/check", body)
  end

  defp upload_pdf(pdf), do: upload([{:file, "report", "report.pdf", pdf}])

  defp main_text(html) do
    html |> LazyHTML.from_document() |> LazyHTML.query("main") |> LazyHTML.text()
  end

  defp outcome(html) do
    [value] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#outcome")
      |> LazyHTML.attribute("data-outcome")

    value
  end

  defp other_keyring do
    {:ok, keyring} = Signing.parse(private_key: Signing.generate().private_key)
    keyring
  end

  defp genuine, do: PDF.render(:assessor, report_fixture(), meta_fixture())

  describe "GET /check" do
    test "offers an upload form and says what a match does and does not mean", %{conn: conn} do
      html = conn |> get(~p"/check") |> html_response(200)

      assert html =~ ~s(enctype="multipart/form-data")
      assert html =~ ~s(name="report")
      assert html =~ ~s(name="_csrf_token")

      text = main_text(html)
      assert text =~ "genuine and unedited"
      assert text =~ "says nothing about who took part"
      assert text =~ "never saved, logged or stored"
    end

    test "is never cached or indexed", %{conn: conn} do
      conn = get(conn, ~p"/check")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "is linked from every page's foot and from the terms", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(href="/check")
      assert build_conn() |> get(~p"/terms") |> html_response(200) =~ ~s(href="/check")
    end
  end

  describe "POST /check" do
    test "a genuine report: genuine and unedited, with its signed content in full" do
      report = report_fixture()
      conn = upload_pdf(genuine())
      html = html_response(conn, 200)

      assert outcome(html) == "match"
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      text = main_text(html)
      assert text =~ "This report is genuine and unedited"
      assert text =~ "It does not say who took part"
      assert text =~ Signing.keyring().current.kid

      for piece <- Content.texts(Content.assessor(report)) do
        assert text =~ piece, "signed content missing: #{piece}"
      end

      for {_label, value} <- Content.header(meta_fixture()), do: assert(text =~ value)
    end

    test "a report signed with a retired key still matches" do
      old = other_keyring()
      pdf = PDF.render(:assessor, report_fixture(), meta_fixture(), old)
      config = Application.get_env(:ai_in_practice, :report_signing)

      Application.put_env(:ai_in_practice, :report_signing,
        private_key: Signing.generate().private_key,
        retired: Base.encode64(old.current.public_key)
      )

      on_exit(fn -> Application.put_env(:ai_in_practice, :report_signing, config) end)

      assert pdf |> upload_pdf() |> html_response(200) |> outcome() == "match"
    end

    test "a payload in a format the page does not know is shown as it was signed" do
      keyring = Signing.keyring()

      pdf =
        edit_envelope(genuine(), fn envelope ->
          envelope
          |> Jason.decode!()
          |> Map.fetch!("payload")
          |> Map.put("format", "ai-in-practice/assessor-report/99")
          |> Signing.envelope(keyring)
        end)

      html = pdf |> upload_pdf() |> html_response(200)
      assert outcome(html) == "match"
      assert html =~ ~s(id="signed-raw")
      assert html =~ "assessor-report/99"
    end

    test "an edited report does not match its signature" do
      edited = edit_envelope(genuine(), &String.replace(&1, "Finance", "Finanze"))
      html = edited |> upload_pdf() |> html_response(200)

      assert outcome(html) == "bad_signature"
      text = main_text(html)
      assert text =~ "could not be confirmed as unedited"
      assert text =~ "has been changed since AI in Practice wrote it"
      refute text =~ "Finanze"
      refute text =~ "genuine and unedited"
    end

    test "a report signed with a key that was never published is not confirmed" do
      pdf = PDF.render(:assessor, report_fixture(), meta_fixture(), other_keyring())
      html = pdf |> upload_pdf() |> html_response(200)

      assert outcome(html) == "unknown_key"
      assert main_text(html) =~ "never published"
    end

    test "damaged signed content is not confirmed" do
      pdf = edit_envelope(genuine(), fn _ -> "not json" end)
      html = pdf |> upload_pdf() |> html_response(200)

      assert outcome(html) == "malformed"
      assert main_text(html) =~ "damaged"
    end

    test "the candidate report has no signed content, and the page says why" do
      pdf = PDF.render(:candidate, report_fixture(), meta_fixture())
      html = pdf |> upload_pdf() |> html_response(200)

      assert outcome(html) == "no_signed_content"
      assert main_text(html) =~ "Only the assessor report is signed"
    end

    test "a file that is not a PDF is refused politely, back on the form" do
      html = "just some text" |> upload_pdf() |> html_response(422)

      assert html =~ ~s(id="check-form")
      assert main_text(html) =~ "That file is not a PDF."
      assert html =~ ~s(aria-invalid="true")
    end

    test "no file chosen is refused politely" do
      for parts <- [[{:file, "report", "", ""}], [{:field, "other", "x"}]] do
        html = parts |> upload() |> html_response(422)
        assert main_text(html) =~ "Choose a PDF to check."
      end
    end

    test "a form that is not multipart at all is treated as no file", %{conn: conn} do
      html = conn |> post(~p"/check", %{"report" => "x"}) |> html_response(422)
      assert main_text(html) =~ "Choose a PDF to check."
    end

    test "a file over the limit is refused politely, and not held in memory" do
      big = "%PDF-1.7\n" <> :binary.copy("x", CheckUpload.limit())
      html = big |> upload_pdf() |> html_response(413)

      assert html =~ ~s(id="check-form")
      assert main_text(html) =~ "larger than 5 MB"
    end

    test "a file exactly at the limit is read" do
      pdf = genuine()
      padded = pdf <> :binary.copy("\n", CheckUpload.limit() - byte_size(pdf))
      assert byte_size(padded) == CheckUpload.limit()

      assert padded |> upload_pdf() |> html_response(200) |> outcome() == "match"
    end

    test "a body far over the limit is refused outright" do
      huge = :binary.copy("x", CheckUpload.discard_limit() + 1)

      assert_raise Plug.Parsers.RequestTooLargeError, fn -> upload_pdf(huge) end

      {type, body} = multipart([{:file, "report", "r.pdf", "%PDF-"}])

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        build_conn()
        |> put_req_header("content-type", type)
        |> put_req_header("content-length", Integer.to_string(CheckUpload.discard_limit() + 1))
        |> post(~p"/check", body)
      end
    end

    test "other files in the form are dropped, and the report is still read" do
      html =
        [
          {:file, "other", "other.pdf", "%PDF-1.7 other"},
          {:file, "report", "report.pdf", genuine()}
        ]
        |> upload()
        |> html_response(200)

      assert outcome(html) == "match"
    end

    test "a part with no name is ignored" do
      html =
        [{:unnamed, "stray"}, {:file, "report", "r.pdf", genuine()}]
        |> upload()
        |> html_response(200)

      assert outcome(html) == "match"
    end

    test "a field longer than any CSRF token is refused outright" do
      # One read, and one long enough to need several.
      for size <- [5_000, 1_500_000] do
        assert_raise Plug.Parsers.RequestTooLargeError, fn ->
          upload([{:field, "_csrf_token", :binary.copy("a", size)}])
        end
      end
    end

    test "a body of many small fields past the limit is refused outright" do
      field = {:field, "f", :binary.copy("a", 4_000)}
      fields = List.duplicate(field, div(CheckUpload.discard_limit(), 4_000) + 1)

      assert_raise Plug.Parsers.RequestTooLargeError, fn -> upload(fields) end
    end

    test "needs the form's CSRF token" do
      {type, body} = multipart([{:file, "report", "report.pdf", genuine()}])

      conn =
        Plug.Test.conn(:post, "/check", body)
        |> put_req_header("content-type", type)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        AiInPracticeWeb.Endpoint.call(conn, [])
      end
    end

    test "with the form's CSRF token and session, a browser's upload is checked" do
      page = AiInPracticeWeb.Endpoint.call(Plug.Test.conn(:get, "/check"), [])
      [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)
      cookie = page |> get_resp_header("set-cookie") |> hd() |> String.split(";") |> hd()

      {type, body} =
        multipart([{:field, "_csrf_token", token}, {:file, "report", "report.pdf", genuine()}])

      conn =
        Plug.Test.conn(:post, "/check", body)
        |> put_req_header("content-type", type)
        |> put_req_header("cookie", cookie)
        |> AiInPracticeWeb.Endpoint.call([])

      assert conn.status == 200
      assert outcome(conn.resp_body) == "match"
    end
  end

  describe "nothing is stored" do
    @describetag :privacy

    defp plug_temp_files, do: Path.wildcard(Path.join(System.tmp_dir!(), "plug-*/**/*"))

    defp my_uploads, do: :ets.lookup(Plug.Upload.Path, self())

    test "an upload makes no temporary file" do
      before = plug_temp_files()
      conn = upload_pdf(genuine())

      assert html_response(conn, 200) |> outcome() == "match"
      assert my_uploads() == []
      assert plug_temp_files() -- before == []
      refute Map.has_key?(conn.params, "report")
      assert conn.private[:check_upload] == nil
    end

    test "the same upload anywhere else would have made one, so the check above means something" do
      {type, body} = multipart([{:file, "report", "report.pdf", "%PDF-1.7"}])

      build_conn()
      |> put_req_header("content-type", type)
      |> post("/elsewhere", body)

      assert [_ | _] = my_uploads()
    end

    test "nothing from a checked report reaches the logs" do
      report = report_fixture(["LOG-MARKER-ANSWER we cut invoice errors by a third"])
      pdf = PDF.render(:assessor, report, meta_fixture())
      edited = edit_envelope(pdf, &String.replace(&1, "LOG-MARKER", "LOG-MARKEE"))

      log =
        GlobalLog.capture(:debug, fn ->
          assert pdf |> upload_pdf() |> html_response(200) =~ "LOG-MARKER-ANSWER"
          assert edited |> upload_pdf() |> html_response(200) |> outcome() == "bad_signature"
          assert "%PDF-1.7 LOG-MARKER" |> upload_pdf() |> html_response(200)
        end)

      assert log =~ "POST /check"
      refute log =~ "LOG-MARKE"
      refute log =~ report.summary
      refute log =~ "%PDF"
    end
  end

  describe "wording" do
    test "no page of the check uses a banned term" do
      pages = [
        build_conn() |> get(~p"/check") |> html_response(200),
        "x" |> upload_pdf() |> html_response(422),
        edit_envelope(genuine(), &String.replace(&1, "Finance", "Finanze"))
        |> upload_pdf()
        |> html_response(200),
        PDF.render(:assessor, report_fixture(), meta_fixture(), other_keyring())
        |> upload_pdf()
        |> html_response(200),
        edit_envelope(genuine(), fn _ -> "x" end) |> upload_pdf() |> html_response(200),
        PDF.render(:candidate, report_fixture(), meta_fixture())
        |> upload_pdf()
        |> html_response(200)
      ]

      for html <- pages, do: assert(VocabularyGuard.banned(main_text(html)) == [])

      # A match, leaving out the signed content itself, which is the report's
      # own words.
      match =
        genuine()
        |> upload_pdf()
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("main > :not(#signed-content)")
        |> LazyHTML.text()

      assert match =~ "genuine and unedited"
      assert VocabularyGuard.banned(match) == []
    end
  end
end
