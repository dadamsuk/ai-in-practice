defmodule AiInPractice.LinksFixtures do
  @moduledoc "Links for tests. Each returns the link and its token."

  import Ecto.Query

  alias AiInPractice.Links
  alias AiInPractice.Links.AssessmentLink
  alias AiInPractice.Repo

  def recruiter_link_fixture(attrs \\ %{}) do
    {:ok, link, token} =
      attrs
      |> Enum.into(%{
        firm_name: "Northgate Search",
        contact_name: "Sam Contact",
        contact_email: "sam@northgate.example",
        quota: 10
      })
      |> Links.create_recruiter_link()

    {link, token}
  end

  def candidate_link_fixture(recruiter, role_group \\ :finance) do
    {:ok, link, token} = Links.mint_candidate_link(recruiter, role_group)
    {link, token}
  end

  def individual_link_fixture(label \\ "IND-001") do
    {:ok, link, token} = Links.create_individual_link(%{label: label})
    {link, token}
  end

  @doc "Moves a link's started_at into the past, to test abandonment."
  def backdate_start(%AssessmentLink{id: id}, seconds_ago) do
    at = DateTime.add(DateTime.utc_now(:second), -seconds_ago)
    Repo.update_all(from(l in AssessmentLink, where: l.id == ^id), set: [started_at: at])
    Repo.get!(AssessmentLink, id)
  end
end
