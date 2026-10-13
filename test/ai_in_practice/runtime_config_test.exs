defmodule AiInPractice.RuntimeConfigTest do
  # Reads config/runtime.exs as production would, to check that the admin
  # listener's bind address comes from ADMIN_IP and that a bad one stops boot.
  use ExUnit.Case, async: false

  alias AiInPractice.AdminBind

  @vars ~w(ADMIN_IP ADMIN_PORT ADMIN_HOST DATABASE_PATH SECRET_KEY_BASE PHX_HOST PORT PUBLIC_IP
           PHX_SERVER FAKE_LLM OPENROUTER_API_KEY REPORT_SIGNING_KEY REPORT_SIGNING_RETIRED_KEYS
           TRANSCRIPTION_SERVICE_URL TRANSCRIPTION_SERVICE_KEY TRANSCRIPTION_SERVICE_MODEL
           FAKE_TRANSCRIBER)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Enum.each(@vars, &System.delete_env/1)
    System.put_env("DATABASE_PATH", "/tmp/ai_in_practice_prod_test.db")
    System.put_env("SECRET_KEY_BASE", String.duplicate("a", 64))
    System.put_env("PHX_HOST", "ai-in-practice.dsc.net")
    System.put_env("OPENROUTER_API_KEY", "sk-or-test")
    :ok
  end

  defp read_prod do
    Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
  end

  defp admin_config(config), do: config[:ai_in_practice][AiInPracticeWeb.AdminEndpoint]
  defp public_config(config), do: config[:ai_in_practice][AiInPracticeWeb.Endpoint]

  describe "required production settings" do
    setup do
      System.put_env("ADMIN_IP", "100.88.155.65")
      :ok
    end

    for var <- ~w(DATABASE_PATH SECRET_KEY_BASE PHX_HOST OPENROUTER_API_KEY) do
      test "refuses to boot without #{var}" do
        System.delete_env(unquote(var))
        assert_raise RuntimeError, ~r/#{unquote(var)} is missing/, fn -> read_prod() end
      end
    end

    test "with everything set, reads the database path, model key and host" do
      config = read_prod()[:ai_in_practice]

      assert config[AiInPractice.Repo][:database] == "/tmp/ai_in_practice_prod_test.db"
      assert config[:openrouter_api_key] == "sk-or-test"

      assert config[AiInPracticeWeb.Endpoint][:url] ==
               [host: "ai-in-practice.dsc.net", port: 443, scheme: "https"]
    end
  end

  describe "public listener" do
    setup do
      System.put_env("ADMIN_IP", "100.88.155.65")
      :ok
    end

    test "accepts LiveView websockets only from the public host" do
      # check_origin left at Phoenix's default compares the Origin with url[:host].
      config = public_config(read_prod())
      refute Keyword.has_key?(config, :check_origin)

      refute Keyword.has_key?(
               Application.get_env(:ai_in_practice, AiInPracticeWeb.Endpoint),
               :check_origin
             )

      assert config[:url][:host] == "ai-in-practice.dsc.net"
    end

    test "binds to every interface on port 4000 by default" do
      http = public_config(read_prod())[:http]
      assert http[:ip] == {0, 0, 0, 0, 0, 0, 0, 0}
      assert http[:port] == 4000
    end

    test "binds to PUBLIC_IP and PORT, e.g. loopback behind a Cloudflare Tunnel" do
      System.put_env("PUBLIC_IP", "127.0.0.1")
      System.put_env("PORT", "4080")
      http = public_config(read_prod())[:http]
      assert http[:ip] == {127, 0, 0, 1}
      assert http[:port] == 4080
    end

    test "refuses a PUBLIC_IP that is not an address" do
      System.put_env("PUBLIC_IP", "localhost")
      assert_raise RuntimeError, ~r/PUBLIC_IP is not an IP address/, fn -> read_prod() end
    end
  end

  test "refuses to boot without ADMIN_IP" do
    assert_raise RuntimeError, ~r/ADMIN_IP is missing/, fn -> read_prod() end
  end

  test "refuses to boot with an ADMIN_IP that is not an address" do
    System.put_env("ADMIN_IP", "tailscale0")
    assert_raise RuntimeError, ~r/ADMIN_IP is not an IP address/, fn -> read_prod() end
  end

  test "binds admin to ADMIN_IP and ADMIN_PORT" do
    System.put_env("ADMIN_IP", "100.88.155.65")
    System.put_env("ADMIN_PORT", "4555")
    http = admin_config(read_prod())[:http]

    assert http[:ip] == {100, 88, 155, 65}
    assert http[:port] == 4555
    assert admin_config(read_prod())[:url][:port] == 4555
    assert AdminBind.validate!(:prod, admin_config(read_prod())) == :ok
  end

  test "an ADMIN_IP of 0.0.0.0 parses but the boot guard refuses it" do
    System.put_env("ADMIN_IP", "0.0.0.0")

    assert_raise ArgumentError, ~r/must not bind to 0\.0\.0\.0/, fn ->
      AdminBind.validate!(:prod, admin_config(read_prod()))
    end
  end

  describe "REPORT_SIGNING_KEY" do
    alias AiInPractice.Reports.Signing

    setup do
      System.put_env("ADMIN_IP", "100.88.155.65")
      :ok
    end

    defp signing_config(config), do: config[:ai_in_practice][:report_signing]

    test "production refuses to boot without it" do
      config = signing_config(read_prod())
      assert config == nil

      assert_raise ArgumentError, ~r/REPORT_SIGNING_KEY/, fn ->
        Signing.validate!(:prod, config)
      end
    end

    test "production boots with it, and with retired keys" do
      key = Signing.generate()
      retired = Signing.generate()
      System.put_env("REPORT_SIGNING_KEY", key.private_key)
      System.put_env("REPORT_SIGNING_RETIRED_KEYS", retired.public_key)
      config = signing_config(read_prod())

      assert Signing.validate!(:prod, config) == :ok
      {:ok, keyring} = Signing.parse(config)
      assert keyring.current.kid == key.kid
      assert [%{kid: kid}] = keyring.retired
      assert kid == retired.kid
    end

    test "an invalid key stops boot" do
      System.put_env("REPORT_SIGNING_KEY", "not-a-key")

      assert_raise ArgumentError, ~r/32-byte/, fn ->
        Signing.validate!(:prod, signing_config(read_prod()))
      end
    end

    test "a release with no key will not sign with an ephemeral one" do
      saved = Application.get_env(:ai_in_practice, :env)
      Application.put_env(:ai_in_practice, :env, :prod)
      on_exit(fn -> Application.put_env(:ai_in_practice, :env, saved) end)

      assert_raise ArgumentError, ~r/REPORT_SIGNING_KEY/, fn -> Signing.keyring() end
    end
  end

  describe "FAKE_LLM" do
    defp read_dev, do: Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)

    test "in dev, 1 selects the fake model and the error modes configure it" do
      System.put_env("FAKE_LLM", "1")
      assert read_dev()[:ai_in_practice][:llm] == {AiInPractice.LLM.Fake, []}

      System.put_env("FAKE_LLM", "spend_refused")

      assert read_dev()[:ai_in_practice][:llm] ==
               {AiInPractice.LLM.Fake, [fail_turn: {0, :spend_refused}]}

      refute read_dev()[:ai_in_practice][:assessment_limits]
    end

    test "short adds a one-minute hard stop" do
      System.put_env("FAKE_LLM", "short")
      config = read_dev()[:ai_in_practice]
      assert config[:llm] == {AiInPractice.LLM.Fake, []}
      assert config[:assessment_limits] == %{hard_stop_ms: 60_000}
    end

    test "an unknown value, or production, leaves the real model alone" do
      System.put_env("FAKE_LLM", "yes please")
      refute read_dev()[:ai_in_practice][:llm]

      System.put_env("FAKE_LLM", "1")
      System.put_env("ADMIN_IP", "100.88.155.65")
      refute read_prod()[:ai_in_practice][:llm]
    end
  end

  describe "TRANSCRIPTION_SERVICE_URL and _KEY" do
    setup do
      System.put_env("ADMIN_IP", "100.88.155.65")
      :ok
    end

    test "with both, production uses the engine's client with the local model" do
      System.put_env("TRANSCRIPTION_SERVICE_URL", "http://bigwhite:8765")
      System.put_env("TRANSCRIPTION_SERVICE_KEY", "mk-test")
      config = read_prod()[:ai_in_practice]

      assert config[:transcriber] == {AiInPractice.Transcriber.Manuel, model: "parakeet"}
      assert config[:transcription_service] == [url: "http://bigwhite:8765", api_key: "mk-test"]
    end

    test "TRANSCRIPTION_SERVICE_MODEL names another model" do
      System.put_env("TRANSCRIPTION_SERVICE_URL", "http://bigwhite:8765")
      System.put_env("TRANSCRIPTION_SERVICE_KEY", "mk-test")
      System.put_env("TRANSCRIPTION_SERVICE_MODEL", "whisper/large-v3-turbo")

      assert read_prod()[:ai_in_practice][:transcriber] ==
               {AiInPractice.Transcriber.Manuel, model: "whisper/large-v3-turbo"}
    end

    test "without either, or with an empty one, voice stays off and boot goes on" do
      refute read_prod()[:ai_in_practice][:transcriber]

      System.put_env("TRANSCRIPTION_SERVICE_URL", "http://bigwhite:8765")
      refute read_prod()[:ai_in_practice][:transcriber]

      System.put_env("TRANSCRIPTION_SERVICE_KEY", "")
      refute read_prod()[:ai_in_practice][:transcriber]
    end
  end

  describe "FAKE_TRANSCRIBER" do
    test "in dev, 1 selects the fake transcriber and the error modes configure it" do
      System.put_env("FAKE_TRANSCRIBER", "1")
      assert read_dev()[:ai_in_practice][:transcriber] == {AiInPractice.Transcriber.Fake, []}

      System.put_env("FAKE_TRANSCRIBER", "no_speech")

      assert read_dev()[:ai_in_practice][:transcriber] ==
               {AiInPractice.Transcriber.Fake, [fail: :no_speech]}
    end

    test "an unknown value, or production, configures nothing" do
      System.put_env("FAKE_TRANSCRIBER", "loud")
      refute read_dev()[:ai_in_practice][:transcriber]

      System.put_env("FAKE_TRANSCRIBER", "1")
      System.put_env("ADMIN_IP", "100.88.155.65")
      refute read_prod()[:ai_in_practice][:transcriber]
    end
  end
end
