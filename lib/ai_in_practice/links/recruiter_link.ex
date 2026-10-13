defmodule AiInPractice.Links.RecruiterLink do
  @moduledoc """
  A recruiter-mode link: gives a recruiter a page where they can mint up to
  `quota` single-use candidate links (PRD §6). The firm and contact are
  entered by David (PRD §10 "Kept").
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias AiInPractice.Links.AssessmentLink

  @max_quota 100

  schema "recruiter_links" do
    field :token_hash, :binary
    field :firm_name, :string
    field :contact_name, :string
    field :contact_email, :string
    field :quota, :integer, default: 10
    field :revoked_at, :utc_datetime

    has_many :candidate_links, AssessmentLink

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The largest quota David can set."
  def max_quota, do: @max_quota

  @doc "For creating a link: firm, contact and quota."
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:firm_name, :contact_name, :contact_email, :quota])
    |> update_change(:firm_name, &String.trim/1)
    |> update_change(:contact_name, &String.trim/1)
    |> update_change(:contact_email, &String.trim/1)
    |> validate_required([:firm_name, :contact_name, :contact_email, :quota])
    |> validate_length(:firm_name, max: 200)
    |> validate_length(:contact_name, max: 200)
    |> validate_length(:contact_email, max: 254)
    |> validate_format(:contact_email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/,
      message: "must be an email address"
    )
    |> validate_quota()
  end

  @doc "For changing the quota only."
  def quota_changeset(link, attrs) do
    link
    |> cast(attrs, [:quota])
    |> validate_required([:quota])
    |> validate_quota()
  end

  defp validate_quota(changeset) do
    validate_number(changeset, :quota,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_quota
    )
  end

  @doc false
  def put_token_hash(changeset, hash) do
    changeset
    |> put_change(:token_hash, hash)
    |> unique_constraint(:token_hash)
  end
end
