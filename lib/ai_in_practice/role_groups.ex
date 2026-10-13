defmodule AiInPractice.RoleGroups do
  @moduledoc """
  The seven role groups the rubric calibrates against (PRD §5). The atoms
  are what the database stores; the names are what people read.
  """

  @groups [
    ceo_gm: "CEO or general manager",
    finance: "Finance",
    operations: "Operations",
    commercial: "Commercial",
    people: "People",
    technology_product: "Technology and product",
    board_ned: "Board member or non-executive director"
  ]

  @type t ::
          :ceo_gm
          | :finance
          | :operations
          | :commercial
          | :people
          | :technology_product
          | :board_ned

  @doc "Every role group, in display order."
  @spec all() :: [t()]
  def all, do: Keyword.keys(@groups)

  @doc "The readable name of a role group."
  @spec name(t()) :: String.t()
  def name(group), do: Keyword.fetch!(@groups, group)

  @doc "`{name, value}` pairs for a select input."
  @spec options() :: [{String.t(), String.t()}]
  def options, do: for({group, name} <- @groups, do: {name, Atom.to_string(group)})

  @doc "Parses a role group from a form value, refusing anything unknown."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(group) when is_atom(group), do: if(group in all(), do: {:ok, group}, else: :error)

  def parse(value) when is_binary(value) do
    case Enum.find(all(), &(Atom.to_string(&1) == value)) do
      nil -> :error
      group -> {:ok, group}
    end
  end

  def parse(_), do: :error
end
