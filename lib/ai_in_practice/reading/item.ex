defmodule AiInPractice.Reading.Item do
  @moduledoc """
  One entry on David's curated reading list (PRD §11; rubric "Further
  reading"): a title, a link, who it suits (role groups and rubric areas), a
  one-line note and when it was last checked. Its id is the stable ID the
  report generator picks from.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias AiInPractice.RoleGroups

  @role_groups RoleGroups.all()
  @areas [:understanding, :personal_use, :applying_to_business, :leading_adoption, :attitude]

  schema "reading_items" do
    field :title, :string
    field :url, :string
    field :role_groups, {:array, Ecto.Enum}, values: @role_groups, default: []
    field :areas, {:array, Ecto.Enum}, values: @areas, default: []
    field :note, :string
    field :last_checked_on, :date
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The rubric's five areas, in order."
  def areas, do: @areas

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:title, :url, :role_groups, :areas, :note, :last_checked_on, :active])
    |> update_change(:title, &String.trim/1)
    |> update_change(:url, &String.trim/1)
    |> validate_required([:title, :url])
    |> validate_length(:title, max: 300)
    |> validate_length(:note, max: 300)
    |> validate_length(:url, max: 2000)
    |> validate_url()
    |> validate_areas()
  end

  defp validate_areas(changeset) do
    if get_field(changeset, :areas) in [nil, []] and
         not Keyword.has_key?(changeset.errors, :areas),
       do: add_error(changeset, :areas, "choose at least one area"),
       else: changeset
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [url: "must be a full http or https address"]
      end
    end)
  end
end
