defmodule AiInPractice.AdminBindTest do
  use ExUnit.Case, async: true

  alias AiInPractice.AdminBind

  describe "validate!/2 in prod" do
    test "accepts a specific address, such as a Tailscale one" do
      assert AdminBind.validate!(:prod, http: [ip: {100, 88, 155, 65}, port: 4001]) == :ok

      assert AdminBind.validate!(:prod, http: [ip: {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}]) ==
               :ok
    end

    test "refuses a missing address" do
      assert_raise ArgumentError, ~r/no bind address.*ADMIN_IP/, fn ->
        AdminBind.validate!(:prod, http: [port: 4001])
      end

      assert_raise ArgumentError, ~r/no bind address/, fn -> AdminBind.validate!(:prod, nil) end
    end

    test "refuses 0.0.0.0 and ::" do
      assert_raise ArgumentError, ~r/must not bind to 0\.0\.0\.0/, fn ->
        AdminBind.validate!(:prod, http: [ip: {0, 0, 0, 0}])
      end

      assert_raise ArgumentError, ~r/must not bind to ::/, fn ->
        AdminBind.validate!(:prod, http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}])
      end
    end

    test "refuses an address that is not an IP tuple" do
      assert_raise ArgumentError, ~r/not an IP tuple/, fn ->
        AdminBind.validate!(:prod, http: [ip: "100.88.155.65"])
      end
    end
  end

  test "validate!/2 does not restrict dev or test" do
    assert AdminBind.validate!(:dev, http: [ip: {0, 0, 0, 0}]) == :ok
    assert AdminBind.validate!(:test, nil) == :ok
  end

  describe "parse_ip!/1" do
    test "parses IPv4 and IPv6" do
      assert AdminBind.parse_ip!("100.88.155.65") == {100, 88, 155, 65}
      assert AdminBind.parse_ip!("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "raises on anything else" do
      assert_raise ArgumentError, ~r/not an IP address/, fn -> AdminBind.parse_ip!("dedev") end
    end
  end
end
