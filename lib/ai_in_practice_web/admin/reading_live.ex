defmodule AiInPracticeWeb.Admin.ReadingLive do
  @moduledoc """
  The admin reading list (PRD §11; rubric "Further reading"): add, edit,
  retire and delete the entries the report generator may recommend. Only
  active entries are offered to it.
  """
  use AiInPracticeWeb, :admin_live_view

  alias AiInPractice.Reading
  alias AiInPractice.Reading.Item
  alias AiInPractice.RoleGroups

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Reading list") |> edit(%Item{}) |> load()}
  end

  defp load(socket), do: assign(socket, items: Reading.list_items())

  defp edit(socket, item, changeset \\ nil) do
    assign(socket,
      item: item,
      form: to_form(changeset || Reading.change_item(item), as: :item)
    )
  end

  @impl true
  def handle_event("validate", %{"item" => params}, socket) do
    changeset =
      socket.assigns.item
      |> Reading.change_item(normalise(params))
      |> Map.put(:action, :validate)

    {:noreply, edit(socket, socket.assigns.item, changeset)}
  end

  def handle_event("save", %{"item" => params}, socket) do
    params = normalise(params)

    result =
      case socket.assigns.item do
        %Item{id: nil} -> Reading.create_item(params)
        item -> Reading.update_item(item, params)
      end

    case result do
      {:ok, item} ->
        {:noreply, socket |> put_flash(:info, "Saved #{item.title}.") |> edit(%Item{}) |> load()}

      {:error, changeset} ->
        {:noreply, edit(socket, socket.assigns.item, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Reading.get_item(id) do
      nil -> {:noreply, put_flash(socket, :error, "That entry no longer exists.")}
      item -> {:noreply, edit(socket, item)}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, edit(socket, %Item{})}

  def handle_event("delete", %{"id" => id}, socket) do
    case Reading.get_item(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That entry no longer exists.") |> load()}

      item ->
        {:ok, _} = Reading.delete_item(item)

        {:noreply,
         socket |> put_flash(:info, "Deleted #{item.title}.") |> edit(%Item{}) |> load()}
    end
  end

  # Multiple selects send nothing when nothing is chosen.
  defp normalise(params) do
    params
    |> Map.put_new("role_groups", [])
    |> Map.put_new("areas", [])
    |> Map.update!("role_groups", &List.wrap/1)
    |> Map.update!("areas", &List.wrap/1)
  end

  defp area_options, do: for(a <- Item.areas(), do: {area_name(a), Atom.to_string(a)})

  defp area_name(area), do: area |> Atom.to_string() |> String.replace("_", " ")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} section="admin" legal_links={false}>
      <nav class="mono admin-nav">
        <.link navigate={~p"/admin"}>links</.link>
        <.link navigate={~p"/admin/reading"}>reading list</.link>
      </nav>

      <h1>Reading list</h1>
      <p>
        The report generator recommends only active entries, by id. Retire an entry by making it inactive rather than deleting it.
      </p>

      <h2>{if @item.id, do: "Edit entry #{@item.id}", else: "Add an entry"}</h2>
      <.form for={@form} id="item-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:title]} label="title" />
        <.input field={@form[:url]} type="url" label="url" />
        <.input
          field={@form[:areas]}
          type="select"
          multiple
          label="areas (at least one)"
          options={area_options()}
        />
        <.input
          field={@form[:role_groups]}
          type="select"
          multiple
          label="role groups (none means all)"
          options={RoleGroups.options()}
        />
        <.input field={@form[:note]} label="note: who it suits, in a line" />
        <.input field={@form[:last_checked_on]} type="date" label="last checked" />
        <.input field={@form[:active]} type="checkbox" label="active" />
        <div class="page-actions">
          <.button variant="primary">Save entry</.button>
          <.button :if={@item.id} type="button" phx-click="cancel">Cancel</.button>
        </div>
      </.form>

      <h2>Entries</h2>
      <p :if={@items == []} class="quiet">None yet.</p>
      <table :if={@items != []} class="table" id="reading-items">
        <thead>
          <tr>
            <th class="mono">id</th>
            <th class="mono">title</th>
            <th class="mono">suits</th>
            <th class="mono">last checked</th>
            <th class="mono">status</th>
            <th><span class="visually-hidden">actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- @items} id={"item-#{item.id}"}>
            <td class="mono">{item.id}</td>
            <td>
              <a href={item.url} rel="noopener noreferrer">{item.title}</a>
              <br :if={item.note} /><span :if={item.note} class="quiet">{item.note}</span>
            </td>
            <td>
              {Enum.map_join(item.areas, ", ", &area_name/1)}
              <br /><span class="quiet">{suits_roles(item)}</span>
            </td>
            <td class="mono">{item.last_checked_on && Date.to_iso8601(item.last_checked_on)}</td>
            <td class="mono" data-status>{if item.active, do: "active", else: "inactive"}</td>
            <td>
              <.button type="button" phx-click="edit" phx-value-id={item.id}>Edit</.button>
              <.button
                type="button"
                phx-click="delete"
                phx-value-id={item.id}
                data-confirm={"Delete #{item.title}? Making it inactive is usually better."}
              >
                Delete
              </.button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  defp suits_roles(%Item{role_groups: []}), do: "all role groups"

  defp suits_roles(%Item{role_groups: groups}),
    do: Enum.map_join(groups, ", ", &RoleGroups.name/1)
end
