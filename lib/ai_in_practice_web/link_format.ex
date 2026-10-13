defmodule AiInPracticeWeb.LinkFormat do
  @moduledoc """
  How link data reads on screen. Dates are ISO-style, so the mono type
  never needs a capital letter (PRD §13.2).
  """

  @doc "A UTC timestamp as `2026-10-13 14:05`, or an empty string."
  @spec datetime(DateTime.t() | nil) :: String.t()
  def datetime(nil), do: ""
  def datetime(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  @doc "A link state, in lower case."
  @spec state(AiInPractice.Links.state()) :: String.t()
  def state(:revoked), do: "withdrawn"
  def state(state) when is_atom(state), do: Atom.to_string(state)
end
