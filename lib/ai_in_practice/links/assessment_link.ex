defmodule AiInPractice.Links.AssessmentLink do
  @moduledoc """
  A single-use assessment link (PRD §6).

  * `:candidate` links are minted by a recruiter from their recruiter link.
    The recruiter sets the role group.
  * `:individual` links are issued by David with a label of his choosing
    (e.g. "IND-014"). The person picks their role group at the start.

  A link moves from `:unused` to `:started` when the first question has been
  shown, and to `:completed` when the reports have been generated. Nothing
  about the person taking it is stored here (PRD §10).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias AiInPractice.Links.RecruiterLink
  alias AiInPractice.RoleGroups

  @role_groups RoleGroups.all()

  schema "assessment_links" do
    field :token_hash, :binary
    field :kind, Ecto.Enum, values: [:candidate, :individual]
    field :role_group, Ecto.Enum, values: @role_groups
    field :label, :string
    field :mode, Ecto.Enum, values: [:text, :voice]
    field :status, Ecto.Enum, values: [:unused, :started, :completed], default: :unused
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :recruiter_link, RecruiterLink

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "A candidate link: needs a recruiter link and a role group, never a label."
  def candidate_changeset(link, attrs) do
    link
    |> cast(attrs, [:recruiter_link_id, :role_group])
    |> put_change(:kind, :candidate)
    |> validate_required([:recruiter_link_id, :role_group])
  end

  @doc "An individual link: needs a label, never a recruiter."
  def individual_changeset(link, attrs) do
    link
    |> cast(attrs, [:label])
    |> update_change(:label, &String.trim/1)
    |> put_change(:kind, :individual)
    |> validate_required([:label])
    |> validate_length(:label, max: 40)
  end

  @doc """
  Checks what is chosen at the start of a session: the mode, and the role
  group for an individual link. A candidate link's role group was set by the
  recruiter and cannot be changed here.
  """
  def start_changeset(%__MODULE__{kind: kind} = link, attrs) do
    fields = if kind == :individual, do: [:role_group, :mode], else: [:mode]

    link
    |> cast(attrs, fields)
    |> then(fn cs -> if get_field(cs, :mode), do: cs, else: put_change(cs, :mode, :text) end)
    |> validate_required([:role_group, :mode])
  end

  @doc false
  def put_token_hash(changeset, hash) do
    changeset
    |> put_change(:token_hash, hash)
    |> unique_constraint(:token_hash)
  end
end
