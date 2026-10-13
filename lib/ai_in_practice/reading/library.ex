defmodule AiInPractice.Reading.Library do
  @moduledoc """
  Imports the AI Leaders Library (`priv/reading/library.json`, #766) into
  the reading list.

  Each resource is matched to an entry by its library id (`slug`): new ones
  are added, existing ones updated in place (so their reading-list id, which
  reports refer to, never changes), and entries from an earlier import that
  are no longer in the file are made inactive. Entries added by hand in
  admin, with no slug, are left alone.

  The library's tags are kept as they are (`levels`, `focus`, `audiences`),
  and also mapped onto the reading list's own:

    * audience to role groups: "All senior leaders" suits every role (no
      groups); "Board & non-executives" is Board member or NED; "CEO &
      executive team" is CEO or GM; "Functional leaders" is Finance,
      Operations, Commercial and People; "Risk, legal & compliance" is
      Finance and Operations; "Technology leaders" is Technology and product.
    * focus to the rubric's areas: see `@focus_areas`.
  """

  import Ecto.Query

  alias AiInPractice.Reading.Item
  alias AiInPractice.Repo

  @audience_groups %{
    "Board & non-executives" => [:board_ned],
    "CEO & executive team" => [:ceo_gm],
    "Functional leaders" => [:finance, :operations, :commercial, :people],
    "Risk, legal & compliance" => [:finance, :operations],
    "Technology leaders" => [:technology_product]
  }

  @focus_areas %{
    "Personal productivity" => [:personal_use],
    "Model choice" => [:personal_use, :understanding],
    "How AI works" => [:understanding],
    "Agents" => [:understanding, :applying_to_business],
    "Security" => [:understanding, :applying_to_business],
    "Use-case selection" => [:applying_to_business],
    "Strategy" => [:applying_to_business],
    "Governance & risk" => [:applying_to_business],
    "Regulation" => [:applying_to_business],
    "Engineering practice" => [:applying_to_business, :leading_adoption],
    "Workforce & change" => [:leading_adoption],
    "Market context" => [:attitude]
  }

  @type summary :: %{
          added: non_neg_integer(),
          updated: non_neg_integer(),
          deactivated: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc "The library file shipped with the app."
  @spec default_path() :: Path.t()
  def default_path, do: Application.app_dir(:ai_in_practice, "priv/reading/library.json")

  @doc """
  Imports the library at `path`. All or nothing: any resource that does not
  validate stops the import and changes nothing.
  """
  @spec load(Path.t()) :: {:ok, summary()} | {:error, String.t()}
  def load(path \\ default_path()) do
    with {:ok, json} <- read(path),
         {:ok, entries} <- entries(json) do
      Repo.transaction(fn -> apply_entries(entries) end)
    end
  end

  # The path comes from the operator at the command line (or is the
  # shipped file), never from a request.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:error, "#{path} is not valid JSON: #{Exception.message(e)}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp entries(%{"resources" => resources} = json) when is_list(resources) do
    checked = checked_on(json["linksCheckedOn"])
    {:ok, Enum.map(resources, &attrs(&1, checked))}
  end

  defp entries(_), do: {:error, "the file has no \"resources\" list"}

  defp checked_on(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp checked_on(_), do: nil

  @doc false
  def attrs(resource, checked_on) do
    audiences = list(resource["audience"])
    focus = list(resource["focus"])

    %{
      slug: resource["id"],
      title: resource["title"],
      url: resource["url"],
      author: resource["author"],
      format: resource["format"],
      cost: resource["cost"],
      note: resource["description"],
      levels: list(resource["level"]),
      focus: focus,
      audiences: audiences,
      role_groups: role_groups(audiences),
      areas: areas(focus),
      last_checked_on: checked_on,
      active: true
    }
  end

  @doc "The role groups a resource suits; none means every role."
  @spec role_groups([String.t()]) :: [AiInPractice.RoleGroups.t()]
  def role_groups(audiences) do
    if "All senior leaders" in audiences,
      do: [],
      else:
        audiences
        |> Enum.flat_map(&Map.get(@audience_groups, &1, []))
        |> ordered(AiInPractice.RoleGroups.all())
  end

  @doc "The rubric areas a resource's focus tags speak to."
  @spec areas([String.t()]) :: [atom()]
  def areas(focus),
    do: focus |> Enum.flat_map(&Map.get(@focus_areas, &1, [])) |> ordered(Item.areas())

  defp ordered(values, order), do: Enum.filter(order, &(&1 in values))

  defp list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp list(_), do: []

  defp apply_entries(entries) do
    existing = Repo.all(from i in Item, where: not is_nil(i.slug)) |> Map.new(&{&1.slug, &1})

    counts =
      Enum.reduce(entries, %{added: 0, updated: 0}, fn attrs, counts ->
        case Map.fetch(existing, attrs.slug) do
          {:ok, item} ->
            save!(Item.changeset(item, attrs), attrs)
            Map.update!(counts, :updated, &(&1 + 1))

          :error ->
            save!(Item.changeset(%Item{}, attrs), attrs)
            Map.update!(counts, :added, &(&1 + 1))
        end
      end)

    slugs = Enum.map(entries, & &1.slug)

    {deactivated, _} =
      Repo.update_all(
        from(i in Item, where: not is_nil(i.slug) and i.slug not in ^slugs and i.active),
        set: [active: false, updated_at: DateTime.utc_now(:second)]
      )

    Map.merge(counts, %{deactivated: deactivated, total: length(entries)})
  end

  defp save!(changeset, attrs) do
    case Repo.insert_or_update(changeset) do
      {:ok, item} ->
        item

      {:error, changeset} ->
        errors =
          Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} ->
            "#{field} #{message}"
          end)

        Repo.rollback("resource #{inspect(attrs.slug)}: #{errors}")
    end
  end
end
