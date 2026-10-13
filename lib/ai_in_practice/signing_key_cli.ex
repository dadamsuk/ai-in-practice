defmodule AiInPractice.SigningKeyCLI do
  @moduledoc """
  The report signing key commands (#707). See `AiInPractice.Reports.Signing`.

  In development: `mix signing_key COMMAND`. On a release: `bin/signing_key
  COMMAND`, which runs without the server.

      new          make a new key: the private key for REPORT_SIGNING_KEY,
                   and its public key and id
      public       the public keys this server publishes
      verify FILE  check the signature of an assessor report PDF
  """

  alias AiInPractice.Reports.{PDF, Signing}

  @usage """
  usage:
    signing_key new
    signing_key public
    signing_key verify FILE
  """

  @doc "Runs a command. Returns `{:ok, output}` or `{:error, message}`."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(["new"]) do
    key = Signing.generate()

    {:ok,
     """
     REPORT_SIGNING_KEY=#{key.private_key}

     Keep that line secret: it signs assessor reports. Set it in the server's
     environment. To rotate, move the old public key into
     REPORT_SIGNING_RETIRED_KEYS so reports it signed still verify.

     public key  #{key.public_key}
     key id      #{key.kid}
     """}
  end

  def run(["public"]) do
    lines =
      for key <- Signing.public_keys(),
          do: "#{key["kid"]}  #{key["status"]}  #{key["public_key"]}"

    {:ok, Enum.join(lines, "\n") <> "\n"}
  end

  def run(["verify", path]) do
    with {:ok, pdf} <- read(path),
         {:ok, envelope} <- envelope(pdf),
         {:ok, payload} <- verify(envelope) do
      {:ok,
       "signature valid: key #{Jason.decode!(envelope)["kid"]}, " <>
         "#{payload["role_group_name"]}, #{payload["date"]}\n"}
    end
  end

  def run(_args), do: {:error, @usage}

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, pdf} -> {:ok, pdf}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp envelope(pdf) do
    case PDF.attachment(pdf, Signing.attachment_name()) do
      {:ok, envelope} -> {:ok, envelope}
      :error -> {:error, "no signed content in this PDF: is it an assessor report?"}
    end
  end

  defp verify(envelope) do
    case Signing.verify(envelope) do
      {:ok, payload} -> {:ok, payload}
      {:error, :unknown_key} -> {:error, "signed with a key this server does not know"}
      {:error, :bad_signature} -> {:error, "signature does not match: the content was changed"}
      {:error, :malformed} -> {:error, "the signed content is malformed"}
    end
  end

  @doc "Entry point for `bin/signing_key`: arguments arrive base64-encoded."
  def eval(encoded) do
    args = encoded |> String.split(" ", trim: true) |> Enum.map(&Base.decode64!/1)

    case run(args) do
      {:ok, out} ->
        IO.write(out)

      {:error, message} ->
        IO.write(:stderr, "error: " <> message)
        System.halt(1)
    end
  end
end
