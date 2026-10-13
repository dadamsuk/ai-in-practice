defmodule AiInPractice.SigningKeyCLITest do
  use AiInPractice.DataCase, async: true

  import AiInPractice.ReportFixtures
  import ExUnit.CaptureIO

  alias AiInPractice.Reports.{PDF, Signing}
  alias AiInPractice.SigningKeyCLI

  @moduletag :tmp_dir

  defp write(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  # The PDF with its embedded envelope edited by `fun`, written back as a
  # Flate stream (cross-reference offsets are not fixed: the reader does not
  # use them).
  defp edit_envelope(pdf, fun) do
    {:ok, envelope} = PDF.attachment(pdf, Signing.attachment_name())
    edited = fun.(envelope)
    assert edited != envelope
    data = :zlib.compress(edited)

    [{at, len}, {length_at, length_len}] =
      Regex.run(~r{<</Length (\d+)/Type/EmbeddedFile.*?>>\nstream\n}s, pdf, return: :index)

    old_length = pdf |> binary_part(length_at, length_len) |> String.to_integer()

    dict =
      pdf |> binary_part(at, len) |> String.replace(~r{/Length \d+}, "/Length #{byte_size(data)}")

    dict =
      if dict =~ "/FlateDecode",
        do: dict,
        else: String.replace(dict, "/Type/EmbeddedFile", "/Type/EmbeddedFile/Filter/FlateDecode")

    tail_at = at + len + old_length

    binary_part(pdf, 0, at) <> dict <> data <> binary_part(pdf, tail_at, byte_size(pdf) - tail_at)
  end

  test "new prints a key that parses, with its public key and id" do
    assert {:ok, out} = SigningKeyCLI.run(["new"])
    [_, private] = Regex.run(~r/^REPORT_SIGNING_KEY=(\S+)$/m, out)
    assert {:ok, %{current: key}} = Signing.parse(private_key: private)

    assert out =~ "public key  #{Base.encode64(key.public_key)}"
    assert out =~ "key id      #{key.kid}"
    assert out =~ "REPORT_SIGNING_RETIRED_KEYS"
  end

  test "new makes a different key each time" do
    {:ok, a} = SigningKeyCLI.run(["new"])
    {:ok, b} = SigningKeyCLI.run(["new"])
    assert a != b
  end

  test "public lists the published keys" do
    [key] = Signing.public_keys()
    assert {:ok, out} = SigningKeyCLI.run(["public"])
    assert out == "#{key["kid"]}  current  #{key["public_key"]}\n"
  end

  test "verify accepts an assessor report signed by this server", %{tmp_dir: dir} do
    path = write(dir, "a.pdf", PDF.render(:assessor, report_fixture(), meta_fixture()))

    assert {:ok, out} = SigningKeyCLI.run(["verify", path])
    assert out =~ "signature valid: key #{Signing.keyring().current.kid}, Finance, 2026-10-13"
  end

  test "verify rejects a report signed by another key", %{tmp_dir: dir} do
    {:ok, other} = Signing.parse(private_key: Signing.generate().private_key)
    path = write(dir, "a.pdf", PDF.render(:assessor, report_fixture(), meta_fixture(), other))

    assert SigningKeyCLI.run(["verify", path]) ==
             {:error, "signed with a key this server does not know"}
  end

  test "verify rejects a report whose signed content was edited", %{tmp_dir: dir} do
    pdf = PDF.render(:assessor, report_fixture(), meta_fixture())
    edited = edit_envelope(pdf, &String.replace(&1, "Finance", "Finanze"))

    assert SigningKeyCLI.run(["verify", write(dir, "a.pdf", edited)]) ==
             {:error, "signature does not match: the content was changed"}
  end

  test "verify rejects malformed signed content", %{tmp_dir: dir} do
    pdf = PDF.render(:assessor, report_fixture(), meta_fixture())
    edited = edit_envelope(pdf, &String.replace(&1, "Ed25519", "Ed25518"))

    assert SigningKeyCLI.run(["verify", write(dir, "a.pdf", edited)]) ==
             {:error, "the signed content is malformed"}
  end

  test "verify explains a candidate report, a missing file and bad arguments", %{tmp_dir: dir} do
    path = write(dir, "c.pdf", PDF.render(:candidate, report_fixture(), meta_fixture()))
    assert {:error, "no signed content" <> _} = SigningKeyCLI.run(["verify", path])

    assert {:error, "cannot read " <> rest} =
             SigningKeyCLI.run(["verify", Path.join(dir, "none.pdf")])

    assert rest =~ "no such file"

    for args <- [[], ["verify"], ["old"], ["new", "x"]] do
      assert {:error, "usage:" <> _} = SigningKeyCLI.run(args)
    end
  end

  test "eval decodes base64 arguments and prints the result" do
    out = capture_io(fn -> SigningKeyCLI.eval(" " <> Base.encode64("public")) end)
    assert out =~ "current"
  end
end
