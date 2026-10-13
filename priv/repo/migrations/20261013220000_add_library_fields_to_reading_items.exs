defmodule AiInPractice.Repo.Migrations.AddLibraryFieldsToReadingItems do
  use Ecto.Migration

  # The AI Leaders Library (#766): each entry keeps its library id (slug),
  # so an import updates it in place, and the library's own tags.
  def change do
    alter table(:reading_items) do
      add :slug, :string
      add :author, :string
      add :format, :string
      add :cost, :string
      add :levels, :string, null: false, default: "[]"
      add :focus, :string, null: false, default: "[]"
      add :audiences, :string, null: false, default: "[]"
    end

    create unique_index(:reading_items, [:slug])
  end
end
