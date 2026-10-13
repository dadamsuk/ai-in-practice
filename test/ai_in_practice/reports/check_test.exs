defmodule AiInPractice.Reports.CheckTest do
  use AiInPractice.DataCase, async: true

  import AiInPractice.ReportFixtures

  alias AiInPractice.Reports.{Check, Payload, PDF, Signing}

  defp keyring do
    {:ok, keyring} = Signing.parse(private_key: Signing.generate().private_key)
    keyring
  end

  defp assessor_pdf(keyring), do: PDF.render(:assessor, report_fixture(), meta_fixture(), keyring)

  test "a genuine assessor report gives back its signed payload and key id" do
    keyring = keyring()

    assert {:ok, %{payload: payload, kid: kid}} = Check.check(assessor_pdf(keyring), keyring)
    assert payload == Payload.assessor(report_fixture(), meta_fixture())
    assert kid == keyring.current.kid
  end

  test "checks against the configured keys by default" do
    pdf = PDF.render(:assessor, report_fixture(), meta_fixture())
    assert {:ok, %{kid: kid}} = Check.check(pdf)
    assert kid == Signing.keyring().current.kid
  end

  test "a report signed with a key since retired still matches" do
    old = keyring()
    pdf = assessor_pdf(old)

    {:ok, rotated} =
      Signing.parse(
        private_key: Signing.generate().private_key,
        retired: Base.encode64(old.current.public_key)
      )

    assert {:ok, %{kid: kid}} = Check.check(pdf, rotated)
    assert kid == old.current.kid
  end

  test "an edit to the signed content does not match its signature" do
    keyring = keyring()
    edited = edit_envelope(assessor_pdf(keyring), &String.replace(&1, "Finance", "Finanze"))

    assert Check.check(edited, keyring) == {:error, :bad_signature}
  end

  test "a report signed by a key that was never published is not ours" do
    assert Check.check(assessor_pdf(keyring()), keyring()) == {:error, :unknown_key}
  end

  test "content re-signed by another key under a published key id does not match" do
    ours = keyring()
    theirs = keyring()

    forged =
      edit_envelope(assessor_pdf(ours), fn envelope ->
        envelope
        |> Jason.decode!()
        |> Map.fetch!("payload")
        |> Map.put("summary", "A much better summary.")
        |> Signing.sign(theirs)
        |> Map.put("kid", ours.current.kid)
        |> Jason.encode!()
      end)

    assert Check.check(forged, ours) == {:error, :bad_signature}
  end

  test "damaged signed content is malformed" do
    keyring = keyring()

    for edit <- [
          &String.replace(&1, "Ed25519", "Ed25518"),
          fn _ -> "not json" end,
          fn _ -> "[1, 2]" end
        ] do
      assert Check.check(edit_envelope(assessor_pdf(keyring), edit), keyring) ==
               {:error, :malformed}
    end
  end

  test "the candidate report and other PDFs carry no signed content" do
    candidate = PDF.render(:candidate, report_fixture(), meta_fixture())
    assert Check.check(candidate) == {:error, :no_signed_content}
    assert Check.check("%PDF-1.7\n%%EOF\n") == {:error, :no_signed_content}
  end

  test "anything that is not a PDF is refused" do
    for bytes <- ["", "hello", "<html></html>", <<0xFF, 0xD8, 0xFF>>, " %PDF-1.7"] do
      assert Check.check(bytes) == {:error, :not_pdf}
    end
  end
end
