defmodule AiInPractice.Reports.Check do
  @moduledoc """
  Checks an assessor report PDF (PRD §9, §15 v2; #720): finds the signed
  envelope attached to it and checks its Ed25519 signature against the
  published keys (`AiInPractice.Reports.Signing`).

  A good signature says the signed content is exactly what this server
  wrote. It says nothing about the visible pages, which anyone can edit
  without touching the attachment, so whoever checks a report compares the
  signed content with the PDF they hold. Nor does it say who took part.

  Used by the public check page (`/check`) and by `signing_key verify`. The
  PDF is only ever a binary in memory.
  """

  alias AiInPractice.Reports.{PDF, Signing}

  @type reason :: :not_pdf | :no_signed_content | :malformed | :unknown_key | :bad_signature

  @doc """
  The signed payload and the id of the key that signed it, or why the PDF
  cannot be confirmed as unedited.
  """
  @spec check(binary(), Signing.keyring()) ::
          {:ok, %{payload: map(), kid: String.t()}} | {:error, reason()}
  def check(pdf, keyring \\ Signing.keyring())

  def check(<<"%PDF-", _::binary>> = pdf, keyring) do
    with {:ok, json} <- envelope(pdf),
         {:ok, envelope} <- decode(json),
         {:ok, payload} <- Signing.verify(envelope, keyring) do
      {:ok, %{payload: payload, kid: envelope["kid"]}}
    end
  end

  def check(_not_pdf, _keyring), do: {:error, :not_pdf}

  defp envelope(pdf) do
    case PDF.attachment(pdf, Signing.attachment_name()) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :no_signed_content}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = envelope} -> {:ok, envelope}
      _ -> {:error, :malformed}
    end
  end
end
