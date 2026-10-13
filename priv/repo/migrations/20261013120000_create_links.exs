defmodule AiInPractice.Repo.Migrations.CreateLinks do
  use Ecto.Migration

  # The only persistent data in the app (PRD §10 "Kept"). Tokens are stored
  # as SHA-256 hashes. There is no column for a candidate's name, contact
  # details, transcript or report, and there must never be one.
  def change do
    create table(:recruiter_links) do
      add :token_hash, :binary, null: false
      add :firm_name, :string, null: false
      add :contact_name, :string, null: false
      add :contact_email, :string, null: false
      add :quota, :integer, null: false, default: 10
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:recruiter_links, [:token_hash])

    create table(:assessment_links) do
      add :token_hash, :binary, null: false
      add :kind, :string, null: false
      add :recruiter_link_id, references(:recruiter_links, on_delete: :restrict)
      add :role_group, :string
      add :label, :string
      add :mode, :string
      add :status, :string, null: false, default: "unused"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assessment_links, [:token_hash])
    create index(:assessment_links, [:recruiter_link_id])
  end
end
