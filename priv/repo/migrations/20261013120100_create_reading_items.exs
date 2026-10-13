defmodule AiInPractice.Repo.Migrations.CreateReadingItems do
  use Ecto.Migration

  # David's curated reading list (PRD §11; rubric "Further reading").
  def change do
    create table(:reading_items) do
      add :title, :string, null: false
      add :url, :string, null: false
      add :role_groups, :string, null: false, default: "[]"
      add :areas, :string, null: false, default: "[]"
      add :note, :string
      add :last_checked_on, :date
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end
  end
end
