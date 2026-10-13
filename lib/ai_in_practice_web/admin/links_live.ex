defmodule AiInPracticeWeb.Admin.LinksLive do
  @moduledoc """
  The admin links page (PRD §11), on the Tailscale-only admin endpoint:
  issue recruiter-mode and individual-mode links, adjust quotas, revoke
  links, and see usage.

  A new link's URL is shown once, here, because only its hash is stored.
  """
  use AiInPracticeWeb, :admin_live_view

  alias AiInPractice.Links
  alias AiInPracticeWeb.{LinkFormat, LinkURLs}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Links", issued: nil)
     |> assign_recruiter_form(Links.change_recruiter_link())
     |> assign_individual_form(Links.change_individual_link())
     |> load()}
  end

  defp load(socket), do: assign(socket, usage: Links.usage())

  defp assign_recruiter_form(socket, changeset),
    do: assign(socket, recruiter_form: to_form(changeset, as: :recruiter))

  defp assign_individual_form(socket, changeset),
    do: assign(socket, individual_form: to_form(changeset, as: :individual))

  @impl true
  def handle_event("validate_recruiter", %{"recruiter" => params}, socket) do
    changeset = params |> Links.change_recruiter_link() |> Map.put(:action, :validate)
    {:noreply, assign_recruiter_form(socket, changeset)}
  end

  def handle_event("create_recruiter", %{"recruiter" => params}, socket) do
    case Links.create_recruiter_link(params) do
      {:ok, link, token} ->
        {:noreply,
         socket
         |> assign(
           issued: %{
             what: "Recruiter link for #{link.firm_name}",
             url: LinkURLs.recruiter_url(token)
           }
         )
         |> assign_recruiter_form(Links.change_recruiter_link())
         |> load()}

      {:error, changeset} ->
        {:noreply, assign_recruiter_form(socket, changeset)}
    end
  end

  def handle_event("create_individual", %{"individual" => params}, socket) do
    case Links.create_individual_link(params) do
      {:ok, link, token} ->
        {:noreply,
         socket
         |> assign(
           issued: %{
             what: "Individual link #{link.label}",
             url: LinkURLs.assessment_url(token)
           }
         )
         |> assign_individual_form(Links.change_individual_link())
         |> load()}

      {:error, changeset} ->
        {:noreply, assign_individual_form(socket, changeset)}
    end
  end

  def handle_event("set_quota", %{"recruiter_id" => id, "quota" => quota}, socket) do
    with %{} = recruiter <- Links.get_recruiter_link(id),
         {:ok, recruiter} <- Links.set_quota(recruiter, quota) do
      {:noreply,
       socket
       |> put_flash(:info, "Quota for #{recruiter.firm_name} is now #{recruiter.quota}.")
       |> load()}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A quota must be a whole number from 0 to #{Links.RecruiterLink.max_quota()}."
         )}
    end
  end

  def handle_event("revoke_recruiter", %{"id" => id}, socket) do
    result =
      with %{} = link <- Links.get_recruiter_link(id), do: Links.revoke_recruiter_link(link)

    {:noreply, socket |> revoke_flash(result) |> load()}
  end

  def handle_event("revoke_link", %{"id" => id}, socket) do
    result =
      with %{} = link <- Links.get_assessment_link(id), do: Links.revoke_assessment_link(link)

    {:noreply, socket |> revoke_flash(result) |> load()}
  end

  defp revoke_flash(socket, {:ok, _}), do: put_flash(socket, :info, "Link revoked.")

  defp revoke_flash(socket, _),
    do: put_flash(socket, :error, "That link was not found or is already revoked.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} section="admin" legal_links={false}>
      <nav class="mono admin-nav">
        <.link navigate={~p"/admin"}>links</.link>
        <.link navigate={~p"/admin/reading"}>reading list</.link>
      </nav>

      <h1>Links</h1>

      <section :if={@issued} id="issued" class="notice">
        <h2>{@issued.what}</h2>
        <p><code id="issued-url">{@issued.url}</code></p>
        <p>Copy it now. It is shown only once: the app keeps a hash of the token, not the token.</p>
      </section>

      <h2>Issue a recruiter link</h2>
      <.form
        for={@recruiter_form}
        id="recruiter-form"
        phx-change="validate_recruiter"
        phx-submit="create_recruiter"
      >
        <.input field={@recruiter_form[:firm_name]} label="firm" />
        <.input field={@recruiter_form[:contact_name]} label="contact name" />
        <.input field={@recruiter_form[:contact_email]} type="email" label="contact email" />
        <.input field={@recruiter_form[:quota]} type="number" label="quota" min="0" />
        <.button variant="primary">Issue recruiter link</.button>
      </.form>

      <h2>Issue an individual link</h2>
      <.form for={@individual_form} id="individual-form" phx-submit="create_individual">
        <.input field={@individual_form[:label]} label="label, e.g. ind-014" />
        <.button variant="primary">Issue individual link</.button>
      </.form>

      <h2>Recruiter links</h2>
      <p :if={@usage.recruiters == []} class="quiet">None yet.</p>
      <table :if={@usage.recruiters != []} class="table table-wide" id="recruiter-usage">
        <thead>
          <tr>
            <th class="mono">firm</th>
            <th class="mono">contact</th>
            <th class="mono">minted</th>
            <th class="mono">started</th>
            <th class="mono">completed</th>
            <th class="mono">abandoned</th>
            <th class="mono">quota</th>
            <th class="mono">created</th>
            <th><span class="visually-hidden">actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @usage.recruiters} id={"recruiter-#{row.link.id}"}>
            <td>{row.link.firm_name}</td>
            <td>{row.link.contact_name}<br /><span class="quiet">{row.link.contact_email}</span></td>
            <td class="mono" data-count="minted">{row.minted}</td>
            <td class="mono" data-count="started">{row.started}</td>
            <td class="mono" data-count="completed">{row.completed}</td>
            <td class="mono" data-count="abandoned">{row.abandoned}</td>
            <td class="mono">
              <span data-count="quota-used">{row.quota_used}</span>
              of
              <form
                :if={is_nil(row.link.revoked_at)}
                class="inline-form"
                id={"quota-form-#{row.link.id}"}
                phx-submit="set_quota"
              >
                <input type="hidden" name="recruiter_id" value={row.link.id} />
                <input
                  type="number"
                  name="quota"
                  value={row.link.quota}
                  min="0"
                  aria-label={"quota for #{row.link.firm_name}"}
                />
                <.button type="submit">Set</.button>
              </form>
              <span :if={row.link.revoked_at}>{row.link.quota}</span>
            </td>
            <td class="mono">{LinkFormat.datetime(row.link.inserted_at)}</td>
            <td>
              <span :if={row.link.revoked_at} class="mono">
                revoked {LinkFormat.datetime(row.link.revoked_at)}
              </span>
              <.button
                :if={is_nil(row.link.revoked_at)}
                type="button"
                phx-click="revoke_recruiter"
                phx-value-id={row.link.id}
                data-confirm={"Revoke the link for #{row.link.firm_name}? Their unused candidate links stop working too."}
              >
                Revoke
              </.button>
            </td>
          </tr>
        </tbody>
      </table>
      <p class="quiet">
        Started: in progress, under an hour ago. Abandoned: started over an hour ago and not completed. Quota in use counts unused and completed links.
      </p>

      <h2>Individual links</h2>
      <p :if={@usage.individuals == []} class="quiet">None yet.</p>
      <table :if={@usage.individuals != []} class="table table-wide" id="individual-usage">
        <thead>
          <tr>
            <th class="mono">label</th>
            <th class="mono">status</th>
            <th class="mono">role group</th>
            <th class="mono">created</th>
            <th class="mono">started</th>
            <th class="mono">completed</th>
            <th><span class="visually-hidden">actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @usage.individuals} id={"individual-#{row.link.id}"}>
            <td>{row.link.label}</td>
            <td class="mono" data-status>{individual_state(row)}</td>
            <td>{Links.role_group_name(row.link.role_group)}</td>
            <td class="mono">{LinkFormat.datetime(row.link.inserted_at)}</td>
            <td class="mono">{LinkFormat.datetime(row.link.started_at)}</td>
            <td class="mono">{LinkFormat.datetime(row.link.completed_at)}</td>
            <td>
              <.button
                :if={row.state == :unused}
                type="button"
                phx-click="revoke_link"
                phx-value-id={row.link.id}
                data-confirm={"Revoke #{row.link.label}? It will stop working."}
              >
                Revoke
              </.button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  defp individual_state(%{state: :revoked}), do: "revoked"
  defp individual_state(%{state: state}), do: LinkFormat.state(state)
end
