defmodule AiInPractice.Reports.Signing do
  @moduledoc """
  Ed25519 signatures for the assessor report (PRD §9, §13.1; #707).

  The signed thing is an **envelope**, embedded in the assessor PDF as the
  attached file `ai-in-practice-signed-report.json`:

      {"alg": "Ed25519", "kid": "…", "payload": {…}, "signature": "…"}

  `signature` is the standard Base64 of the Ed25519 signature over
  `AiInPractice.Reports.Canonical.encode!(payload)`. A verifier extracts the
  envelope, re-encodes `payload` canonically, looks up `kid` among the
  published keys and checks the signature. Only the assessor report is
  signed.

  ## Keys

  The private key is a 32-byte Ed25519 seed, Base64 in the
  `REPORT_SIGNING_KEY` environment variable (`mix signing_key new` makes
  one). There is no key in the repository. A key's id (`kid`) is the first
  16 hex digits of the SHA-256 of its public key, so it needs no
  configuring and cannot drift from the key.

  **Rotation:** set the new key in `REPORT_SIGNING_KEY` and move the old
  public key into `REPORT_SIGNING_RETIRED_KEYS` (comma-separated Base64).
  Reports signed with a retired key still verify. Every public key is
  published at `/.well-known/ai-in-practice/signing-keys.json`.

  In production the application refuses to boot without a valid key
  (`validate!/2`). Elsewhere, with none configured, an ephemeral key is
  made once per boot, so development and tests need no secret.
  """

  alias AiInPractice.Reports.Canonical

  @alg "Ed25519"
  @attachment "ai-in-practice-signed-report.json"
  @well_known "/.well-known/ai-in-practice/signing-keys.json"

  @missing "no report signing key: set REPORT_SIGNING_KEY (make one with `bin/signing_key new`)"

  @type key :: %{kid: String.t(), public_key: binary(), private_key: binary() | nil}
  @type keyring :: %{current: key(), retired: [key()]}

  @doc "The file name of the envelope attached to the assessor PDF."
  def attachment_name, do: @attachment

  @doc "The path the public keys are published at."
  def well_known_path, do: @well_known

  ## Signing and verifying

  @doc "Signs `payload` with the current key and returns the envelope."
  @spec sign(Canonical.json() | map(), keyring()) :: map()
  def sign(payload, keyring \\ keyring()) do
    %{current: %{kid: kid, private_key: private}} = keyring
    message = Canonical.encode!(payload)
    signature = :crypto.sign(:eddsa, :none, message, [private, :ed25519])

    %{
      "alg" => @alg,
      "kid" => kid,
      "payload" => payload,
      "signature" => Base.encode64(signature)
    }
  end

  @doc "The envelope for `payload`, as the canonical JSON bytes that are embedded."
  @spec envelope(map(), keyring()) :: binary()
  def envelope(payload, keyring \\ keyring()),
    do: payload |> sign(keyring) |> Canonical.encode!()

  @doc """
  Verifies an envelope (JSON bytes or a decoded map) against the published
  keys. Returns the payload, or why it does not verify.
  """
  @spec verify(binary() | map(), keyring()) ::
          {:ok, map()} | {:error, :malformed | :unknown_key | :bad_signature}
  def verify(envelope, keyring \\ keyring())

  def verify(json, keyring) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> verify(map, keyring)
      _ -> {:error, :malformed}
    end
  end

  def verify(
        %{"alg" => @alg, "kid" => kid, "payload" => payload, "signature" => sig},
        keyring
      )
      when is_binary(kid) and is_map(payload) and is_binary(sig) do
    with {:ok, signature} <- decode_signature(sig),
         {:ok, message} <- canonical(payload),
         {:ok, public} <- find_key(kid, keyring) do
      if :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519]),
        do: {:ok, payload},
        else: {:error, :bad_signature}
    end
  end

  def verify(_envelope, _keyring), do: {:error, :malformed}

  defp decode_signature(sig) do
    case Base.decode64(sig) do
      {:ok, <<_::binary-size(64)>> = bytes} -> {:ok, bytes}
      _ -> {:error, :malformed}
    end
  end

  defp canonical(payload) do
    {:ok, Canonical.encode!(payload)}
  rescue
    ArgumentError -> {:error, :malformed}
  end

  defp find_key(kid, %{current: current, retired: retired}) do
    case Enum.find([current | retired], &(&1.kid == kid)) do
      nil -> {:error, :unknown_key}
      key -> {:ok, key.public_key}
    end
  end

  ## Keys

  @doc "The public keys to publish: the current one first, then retired ones."
  @spec public_keys(keyring()) :: [map()]
  def public_keys(keyring \\ keyring()) do
    [{keyring.current, "current"} | Enum.map(keyring.retired, &{&1, "retired"})]
    |> Enum.map(fn {key, status} ->
      %{
        "kid" => key.kid,
        "alg" => @alg,
        "public_key" => Base.encode64(key.public_key),
        "status" => status
      }
    end)
  end

  @doc "A new key, Base64, for `REPORT_SIGNING_KEY`, with its public key and id."
  @spec generate() :: %{private_key: String.t(), public_key: String.t(), kid: String.t()}
  def generate do
    key = from_seed(:crypto.strong_rand_bytes(32))

    %{
      private_key: Base.encode64(key.private_key),
      public_key: Base.encode64(key.public_key),
      kid: key.kid
    }
  end

  @doc "The key id of a public key."
  @spec kid(binary()) :: String.t()
  def kid(public_key),
    do: :sha256 |> :crypto.hash(public_key) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  @doc """
  The configured keyring. With no key configured outside production, an
  ephemeral one, made once per boot.
  """
  @spec keyring() :: keyring()
  def keyring do
    config = Application.get_env(:ai_in_practice, :report_signing, [])

    case parse(config) do
      {:ok, keyring} -> keyring
      {:error, :missing} -> missing(Application.get_env(:ai_in_practice, :env))
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp missing(:prod), do: raise(ArgumentError, @missing)
  defp missing(_env), do: ephemeral()

  defp ephemeral do
    case :persistent_term.get({__MODULE__, :ephemeral}, nil) do
      nil ->
        keyring = %{current: from_seed(:crypto.strong_rand_bytes(32)), retired: []}
        :persistent_term.put({__MODULE__, :ephemeral}, keyring)
        keyring

      keyring ->
        keyring
    end
  end

  @doc """
  Parses the `:report_signing` config: `private_key` (Base64 seed) and
  `retired` (comma-separated Base64 public keys).
  """
  @spec parse(keyword() | nil) :: {:ok, keyring()} | {:error, :missing | String.t()}
  def parse(config) do
    config = config || []

    with {:ok, seed} <- seed(config[:private_key]),
         {:ok, retired} <- retired(config[:retired]) do
      {:ok, %{current: from_seed(seed), retired: retired}}
    end
  end

  defp seed(nil), do: {:error, :missing}
  defp seed(""), do: {:error, :missing}

  defp seed(b64) when is_binary(b64) do
    case decode64(b64) do
      {:ok, <<_::binary-size(32)>> = seed} -> {:ok, seed}
      _ -> {:error, "REPORT_SIGNING_KEY is not a Base64 32-byte Ed25519 seed"}
    end
  end

  defp retired(nil), do: {:ok, []}

  defp retired(list) when is_binary(list) do
    list
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn b64, {:ok, acc} ->
      case decode64(b64) do
        {:ok, <<_::binary-size(32)>> = public} ->
          {:cont, {:ok, acc ++ [%{kid: kid(public), public_key: public, private_key: nil}]}}

        _ ->
          {:halt,
           {:error, "REPORT_SIGNING_RETIRED_KEYS holds a value that is not a Base64 public key"}}
      end
    end)
  end

  # Standard or URL-safe Base64, padded or not.
  defp decode64(b64) do
    b64 = String.trim(b64)

    with :error <- Base.decode64(b64, padding: false),
         do: Base.url_decode64(b64, padding: false)
  end

  defp from_seed(seed) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    %{kid: kid(public), public_key: public, private_key: private}
  end

  @doc """
  Raises in production unless a valid signing key is configured, so a
  release never issues unsigned or ephemerally signed assessor reports.
  Elsewhere it raises only for a key that is set but invalid.
  """
  @spec validate!(atom(), keyword() | nil) :: :ok
  def validate!(env, config) do
    case {env, parse(config)} do
      {_, {:ok, _}} ->
        :ok

      {:prod, {:error, :missing}} ->
        raise ArgumentError, @missing

      {_, {:error, :missing}} ->
        :ok

      {_, {:error, message}} ->
        raise ArgumentError, message
    end
  end
end
