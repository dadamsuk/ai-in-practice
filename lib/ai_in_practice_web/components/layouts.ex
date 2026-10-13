defmodule AiInPracticeWeb.Layouts do
  @moduledoc """
  The page frame: a running head (DSC in plain type, then the framework's
  name) over a 3px structure rule, the page, and a running foot in mono with
  the code, rubric and model versions so the live site can be matched to the
  public repository (PRD §10, §13.2).
  """
  use AiInPracticeWeb, :html

  alias AiInPractice.Version

  embed_templates "layouts/*"

  @doc """
  Renders the app layout.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :section, :string, default: nil, doc: "a mono label after the name, e.g. \"admin\""
  attr :legal_links, :boolean, default: true, doc: "link the privacy notice and terms in the foot"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="running-head">
      <span class="wordmark">DSC</span>
      <span class="title">AI in Practice</span>
      <span :if={@section} class="mono quiet">{@section}</span>
    </header>

    <main id="main" class="page">
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
    </main>

    <.footer legal_links={@legal_links} />
    """
  end

  @doc """
  The running foot: versions in mono, lower case, then the privacy notice
  and terms. Those open in a new tab, so following one from the middle of a
  conversation does not end it.
  """
  attr :legal_links, :boolean, default: true

  def footer(assigns) do
    assigns =
      assign(assigns,
        code: Version.code_version(),
        rubric: Version.rubric_version(),
        model: Version.model()
      )

    ~H"""
    <footer class="running-foot mono" id="running-foot">
      <span>code {@code}</span>
      <span>rubric v{@rubric}</span>
      <span>model {@model}</span>
      <a :if={@legal_links} href={~p"/privacy"} target="_blank" rel="noopener">privacy</a>
      <a :if={@legal_links} href={~p"/terms"} target="_blank" rel="noopener">terms</a>
    </footer>
    """
  end

  @doc """
  Shows the flash group, including the reconnecting notices LiveView needs.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting.")}
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting.")}
      </.flash>
    </div>
    """
  end
end
