defmodule AiInPractice.RuntimeConfigTest do
  # Reads config/runtime.exs as production would, to check that the admin
  # listener's bind address comes from ADMIN_IP and that a bad one stops boot.
  use ExUnit.Case, async: false

  alias AiInPractice.AdminBind

  @vars ~w(ADMIN_IP ADMIN_PORT DATABASE_PATH SECRET_KEY_BASE PHX_HOST PORT PHX_SERVER FAKE_LLM
           REPORT_SIGNING_KEY REPORT_SIGNING_RETIRED_KEYS)

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
    :ok
  end

  defp read_prod do
    Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
  end

  defp admin_config(config), do: config[:ai_in_practice][AiInPracticeWeb.AdminEndpoint]

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
end
