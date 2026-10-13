defmodule AiInPractice.RuntimeConfigTest do
  # Reads config/runtime.exs as production would, to check that the admin
  # listener's bind address comes from ADMIN_IP and that a bad one stops boot.
  use ExUnit.Case, async: false

  alias AiInPractice.AdminBind

  @vars ~w(ADMIN_IP ADMIN_PORT DATABASE_PATH SECRET_KEY_BASE PHX_HOST PORT PHX_SERVER)

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
end
