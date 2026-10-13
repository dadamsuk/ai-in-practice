defmodule AiInPracticeWeb.RecruiterLive do
  @moduledoc """
  The recruiter page, `/r/:token` (PRD §6). The recruiter mints single-use
  candidate links up to their quota, each with a role group, and sees
  whether each one is unused, started or completed.

  A minted link's URL is shown once by the server. The page also keeps it,
  and any label the recruiter adds (e.g. initials), in the recruiter's own
  browser (`localStorage`), through the `.BrowserOnly` hook. Neither is ever
  sent back: the label inputs have no `name`, sit outside any form and carry
  no `phx-` event bindings.
  """
  use AiInPracticeWeb, :live_view

  alias AiInPractice.Links
  alias AiInPractice.RoleGroups
  alias AiInPracticeWeb.{LinkFormat, LinkURLs}

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket = assign(socket, page_title: "Candidate links", minted: nil)

    case Links.get_recruiter_link_by_token(token) do
      nil -> {:ok, assign(socket, state: :not_found)}
      %{revoked_at: %DateTime{}} -> {:ok, assign(socket, state: :revoked)}
      recruiter -> {:ok, socket |> assign(state: :open, recruiter: recruiter) |> load()}
    end
  end

  defp load(socket) do
    recruiter = Links.get_recruiter_link(socket.assigns.recruiter.id)

    if recruiter.revoked_at do
      assign(socket, state: :revoked)
    else
      assign(socket,
        recruiter: recruiter,
        links: Links.list_candidate_links(recruiter),
        used: Links.quota_used(recruiter),
        remaining: Links.quota_remaining(recruiter),
        form: to_form(%{"role_group" => ""})
      )
    end
  end

  @impl true
  def handle_event("mint", %{"role_group" => value}, %{assigns: %{state: :open}} = socket) do
    with {:ok, group} <- RoleGroups.parse(value),
         {:ok, link, token} <- Links.mint_candidate_link(socket.assigns.recruiter, group) do
      {:noreply,
       socket
       |> assign(minted: %{id: link.id, role_group: group, url: LinkURLs.assessment_url(token)})
       |> clear_flash()
       |> load()}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Choose the candidate's role group.")}

      {:error, :quota_reached} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "You have used all your links. Withdraw an unused one, or ask DSC for more."
         )
         |> load()}

      {:error, _} ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("withdraw", %{"id" => id}, %{assigns: %{state: :open}} = socket) do
    case Links.withdraw_candidate_link(socket.assigns.recruiter, id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Link withdrawn. It can no longer be used.") |> load()}

      {:error, _} ->
        {:noreply,
         socket |> put_flash(:error, "That link has already been used or withdrawn.") |> load()}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp storage_key(recruiter, link, field), do: "aip:r#{recruiter.id}:c#{link.id}:#{field}"

  @impl true
  def render(%{state: :open} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>{@recruiter.firm_name}</h1>
      <p class="lede">Send each candidate their own single-use link.</p>

      <.list>
        <:item title="links">
          <span class="mono" id="quota">{@used} of {@recruiter.quota} in use, {@remaining} left</span>
        </:item>
      </.list>

      <p>
        A link is used up when the candidate's first question appears. If a candidate starts and does not finish, the link cannot be reopened, but it stops counting towards your links, so you can send them a new one.
      </p>

      <section :if={@minted} id="minted" class="notice">
        <h2>New link for a {RoleGroups.name(@minted.role_group)} candidate</h2>
        <p><code id="minted-url">{@minted.url}</code></p>
        <p>
          Copy it now and send it to the candidate. It is also kept in this browser, in the table below. DSC keeps no copy it could show you again.
        </p>
      </section>

      <h2>New candidate link</h2>
      <.form for={@form} id="mint-form" phx-submit="mint">
        <.input
          field={@form[:role_group]}
          type="select"
          label="role group"
          prompt="Choose a role group"
          options={RoleGroups.options()}
        />
        <.button variant="primary" disabled={@remaining == 0}>Create link</.button>
      </.form>

      <h2>Your candidate links</h2>
      <p :if={@links == []} class="quiet">No links yet.</p>
      <table :if={@links != []} class="table table-wide" id="candidate-links">
        <thead>
          <tr>
            <th class="mono">role group</th>
            <th class="mono">status</th>
            <th class="mono">created</th>
            <th class="mono">started</th>
            <th class="mono">link (this browser)</th>
            <th class="mono">your label (this browser)</th>
            <th><span class="visually-hidden">actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={link <- @links} id={"link-#{link.id}"}>
            <td>{RoleGroups.name(link.role_group)}</td>
            <td class="mono" data-status>{LinkFormat.state(recruiter_state(link))}</td>
            <td class="mono">{LinkFormat.datetime(link.inserted_at)}</td>
            <td class="mono">{LinkFormat.datetime(link.started_at)}</td>
            <td>
              <span
                id={"url-#{link.id}"}
                class="mono link-url"
                phx-hook=".BrowserOnly"
                phx-update="ignore"
                data-key={storage_key(@recruiter, link, "url")}
                data-value={@minted && @minted.id == link.id && @minted.url}
                data-missing="not kept in this browser"
              ></span>
            </td>
            <td>
              <input
                type="text"
                id={"label-#{link.id}"}
                class="label-input"
                maxlength="40"
                autocomplete="off"
                aria-label="your label for this link, kept in this browser only"
                phx-hook=".BrowserOnly"
                phx-update="ignore"
                data-key={storage_key(@recruiter, link, "label")}
              />
            </td>
            <td>
              <.button
                :if={link.status == :unused and is_nil(link.revoked_at)}
                type="button"
                phx-click="withdraw"
                phx-value-id={link.id}
                data-confirm="Withdraw this link? It will stop working."
              >
                Withdraw
              </.button>
            </td>
          </tr>
        </tbody>
      </table>

      <p class="quiet">
        Labels and link addresses in this table are kept in this browser only and are never sent to DSC. Use initials or a reference if you like. Candidates are told on their start screen that you can see whether they have started and completed.
      </p>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BrowserOnly">
        export default {
          mounted() {
            const key = this.el.dataset.key
            const load = () => {
              try { return window.localStorage.getItem(key) } catch (_e) { return null }
            }
            const store = (value) => {
              try { window.localStorage.setItem(key, value) } catch (_e) {}
            }

            if (this.el.tagName === "INPUT") {
              this.el.value = load() || ""
              this.el.addEventListener("input", () => store(this.el.value))
            } else {
              const fresh = this.el.dataset.value
              if (fresh) store(fresh)
              this.el.textContent = fresh || load() || this.el.dataset.missing || ""
            }
          }
        }
      </script>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @state == :revoked do %>
        <h1>This page has been closed</h1>
        <p>
          New candidate links can no longer be created here. Contact DSC if you think this is a mistake.
        </p>
      <% else %>
        <h1>This link is not recognised</h1>
        <p>Check that you copied the whole address. If it still does not work, contact DSC.</p>
      <% end %>
    </Layouts.app>
    """
  end

  # A withdrawn link reads as "withdrawn"; an old, unfinished one still
  # reads as "started" for the recruiter (PRD §6 shows three states).
  defp recruiter_state(link) do
    case Links.state(link) do
      :abandoned -> :started
      state -> state
    end
  end
end
