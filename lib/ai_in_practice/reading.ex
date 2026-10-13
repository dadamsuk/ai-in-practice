defmodule AiInPractice.Reading do
  @moduledoc """
  David's curated reading list. The report generator chooses only from the
  active entries (`active_items/0`) and refers to them by id; it never
  invents a reference.
  """

  import Ecto.Query

  alias AiInPractice.Reading.Item
  alias AiInPractice.Repo

  @doc "Every entry, active first, then by title."
  def list_items do
    Repo.all(from i in Item, order_by: [desc: i.active, asc: i.title, asc: i.id])
  end

  @doc "The active entries, the only ones the report generator may pick."
  @spec active_items() :: [Item.t()]
  def active_items do
    Repo.all(from i in Item, where: i.active, order_by: [asc: i.id])
  end

  @doc "The ids of the active entries."
  @spec active_ids() :: [pos_integer()]
  def active_ids, do: Enum.map(active_items(), & &1.id)

  @doc "The entry with this id, or nil."
  def get_item(id), do: Repo.get(Item, id)

  @doc "A changeset for the admin form."
  def change_item(item \\ %Item{}, attrs \\ %{}), do: Item.changeset(item, attrs)

  @doc "Adds an entry."
  def create_item(attrs), do: %Item{} |> Item.changeset(attrs) |> Repo.insert()

  @doc "Changes an entry."
  def update_item(%Item{} = item, attrs), do: item |> Item.changeset(attrs) |> Repo.update()

  @doc """
  Removes an entry. Prefer making it inactive: reports already downloaded
  may refer to its id.
  """
  def delete_item(%Item{} = item), do: Repo.delete(item)
end
