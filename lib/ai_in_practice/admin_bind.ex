defmodule AiInPractice.AdminBind do
  @moduledoc """
  Guards the admin listener's bind address.

  The admin pages have no login: being reachable only over Tailscale is the
  only access control (PRD §11, §13.1). In production the admin endpoint must
  be bound to one specific address (the Tailscale interface). A missing
  address, or an unspecified one such as `0.0.0.0` or `::`, would expose admin
  to the internet, so the application refuses to boot.
  """

  @unspecified [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}]

  @doc """
  Returns `:ok`, or raises if `env` is `:prod` and the endpoint config has no
  specific `http: [ip: ...]`.
  """
  @spec validate!(atom(), keyword() | nil) :: :ok
  def validate!(:prod, config) do
    case config |> List.wrap() |> Keyword.get(:http, []) |> Keyword.get(:ip) do
      nil ->
        raise ArgumentError,
              "admin endpoint has no bind address: set ADMIN_IP to this host's Tailscale address"

      ip when ip in @unspecified ->
        raise ArgumentError,
              "admin endpoint must not bind to #{:inet.ntoa(ip)}: set ADMIN_IP to this host's Tailscale address"

      ip when is_tuple(ip) ->
        :ok

      other ->
        raise ArgumentError, "admin endpoint bind address is not an IP tuple: #{inspect(other)}"
    end
  end

  def validate!(_env, _config), do: :ok

  @doc "Parses an IP address string, raising with a clear message if it is invalid."
  @spec parse_ip!(String.t()) :: :inet.ip_address()
  def parse_ip!(string) do
    case :inet.parse_strict_address(String.to_charlist(string)) do
      {:ok, ip} -> ip
      {:error, _} -> raise ArgumentError, "not an IP address: #{inspect(string)}"
    end
  end
end
