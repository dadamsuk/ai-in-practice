defmodule AiInPractice.Reports.SigningTest do
  use ExUnit.Case, async: true

  alias AiInPractice.Reports.{Canonical, Signing}

  defp keyring(retired \\ nil) do
    {:ok, keyring} = Signing.parse(private_key: Signing.generate().private_key, retired: retired)
    keyring
  end

  @payload %{"format" => "test", "summary" => "Plain words.", "areas" => [%{"quotes" => ["a"]}]}

  describe "sign and verify" do
    test "round trip, from the envelope map and from its bytes" do
      keyring = keyring()
      envelope = Signing.sign(@payload, keyring)

      assert envelope["alg"] == "Ed25519"
      assert envelope["kid"] == keyring.current.kid
      assert {:ok, @payload} = Signing.verify(envelope, keyring)
      assert {:ok, @payload} = Signing.verify(Signing.envelope(@payload, keyring), keyring)
    end

    test "the signature covers the canonical bytes of the payload" do
      keyring = keyring()
      sig = Base.decode64!(Signing.sign(@payload, keyring)["signature"])

      assert :crypto.verify(:eddsa, :none, Canonical.encode!(@payload), sig, [
               keyring.current.public_key,
               :ed25519
             ])
    end

    test "key order in the received JSON does not matter" do
      keyring = keyring()
      envelope = Signing.sign(@payload, keyring)

      reordered =
        ~s({"signature":#{Jason.encode!(envelope["signature"])},"payload":{"summary":"Plain words.","areas":[{"quotes":["a"]}],"format":"test"},"kid":"#{envelope["kid"]}","alg":"Ed25519"})

      assert {:ok, _} = Signing.verify(reordered, keyring)
    end

    test "a one-byte change to the payload fails" do
      keyring = keyring()
      bytes = Signing.envelope(@payload, keyring)
      tampered = String.replace(bytes, "Plain words.", "Plain words!")

      assert byte_size(tampered) == byte_size(bytes)
      assert Signing.verify(tampered, keyring) == {:error, :bad_signature}
    end

    test "an edited signature fails" do
      keyring = keyring()
      envelope = Signing.sign(@payload, keyring)
      <<first, rest::binary>> = Base.decode64!(envelope["signature"])

      edited = %{
        envelope
        | "signature" => Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>)
      }

      assert Signing.verify(edited, keyring) == {:error, :bad_signature}
    end

    test "a payload signed by another key does not verify" do
      envelope = Signing.sign(@payload, keyring())
      other = keyring()

      assert Signing.verify(envelope, other) == {:error, :unknown_key}

      # Even under the right key id, the wrong key fails.
      forged = %{envelope | "kid" => other.current.kid}
      assert Signing.verify(forged, other) == {:error, :bad_signature}
    end

    test "a report signed with a retired key still verifies after rotation" do
      old = keyring()
      envelope = Signing.sign(@payload, old)
      new = keyring(Base.encode64(old.current.public_key))

      assert new.current.kid != old.current.kid
      assert {:ok, @payload} = Signing.verify(envelope, new)
    end

    test "malformed envelopes" do
      keyring = keyring()
      good = Signing.sign(@payload, keyring)

      for bad <- [
            "not json",
            "[1,2]",
            %{},
            %{good | "alg" => "RS256"},
            Map.delete(good, "kid"),
            %{good | "payload" => "a string"},
            %{good | "signature" => "%%%"},
            %{good | "signature" => Base.encode64("too short")},
            %{good | "payload" => %{"x" => 1.5}}
          ] do
        assert Signing.verify(bad, keyring) == {:error, :malformed}, inspect(bad)
      end
    end
  end

  describe "keys" do
    test "a generated key parses, and its id comes from its public key" do
      key = Signing.generate()
      assert {:ok, %{current: current, retired: []}} = Signing.parse(private_key: key.private_key)

      assert Base.encode64(current.public_key) == key.public_key
      assert current.kid == key.kid
      assert key.kid == Signing.kid(current.public_key)
      assert key.kid =~ ~r/\A[0-9a-f]{16}\z/
    end

    test "accepts URL-safe and unpadded Base64, with whitespace" do
      seed = :crypto.strong_rand_bytes(32)
      {:ok, a} = Signing.parse(private_key: Base.encode64(seed))

      {:ok, b} =
        Signing.parse(private_key: " " <> Base.url_encode64(seed, padding: false) <> "\n")

      assert a.current.kid == b.current.kid
    end

    test "missing and invalid keys" do
      assert Signing.parse(nil) == {:error, :missing}
      assert Signing.parse([]) == {:error, :missing}
      assert Signing.parse(private_key: "") == {:error, :missing}
      assert {:error, msg} = Signing.parse(private_key: Base.encode64("short"))
      assert msg =~ "REPORT_SIGNING_KEY"
      assert {:error, _} = Signing.parse(private_key: "not base64 !!")

      key = Signing.generate().private_key
      assert {:error, msg} = Signing.parse(private_key: key, retired: "abc!,")
      assert msg =~ "REPORT_SIGNING_RETIRED_KEYS"
      assert {:ok, %{retired: []}} = Signing.parse(private_key: key, retired: " , ")
    end

    test "public keys list the current key first, then retired ones, with no private part" do
      old = Signing.generate()
      keyring = keyring("#{old.public_key}, ")

      assert [current, retired] = Signing.public_keys(keyring)
      assert current["status"] == "current"
      assert current["kid"] == keyring.current.kid

      assert retired == %{
               "kid" => old.kid,
               "alg" => "Ed25519",
               "public_key" => old.public_key,
               "status" => "retired"
             }

      refute inspect(Signing.public_keys(keyring)) =~ Base.encode64(keyring.current.private_key)
    end

    test "with no key configured outside production, one ephemeral key per boot" do
      assert Application.get_env(:ai_in_practice, :report_signing) == nil
      assert Signing.keyring() == Signing.keyring()
      assert byte_size(Signing.keyring().current.public_key) == 32
    end
  end

  describe "the boot guard" do
    test "production refuses to boot without a key" do
      assert_raise ArgumentError, ~r/REPORT_SIGNING_KEY/, fn -> Signing.validate!(:prod, nil) end
      assert_raise ArgumentError, ~r/REPORT_SIGNING_KEY/, fn -> Signing.validate!(:prod, []) end
    end

    test "production boots with a valid key" do
      assert Signing.validate!(:prod, private_key: Signing.generate().private_key) == :ok
    end

    test "an invalid key stops boot anywhere" do
      for env <- [:prod, :dev, :test] do
        assert_raise ArgumentError, fn -> Signing.validate!(env, private_key: "xyz") end
      end
    end

    test "development and test boot without a key" do
      assert Signing.validate!(:dev, nil) == :ok
      assert Signing.validate!(:test, []) == :ok
    end
  end
end
