defmodule AiInPractice.Repo.Migrations.AddQuickToAssessmentLinks do
  use Ecto.Migration

  def change do
    alter table(:assessment_links) do
      add :quick, :boolean, null: false, default: false
    end
  end
end
