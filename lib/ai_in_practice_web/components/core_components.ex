defmodule AiInPracticeWeb.CoreComponents do
  @moduledoc """
  Core UI components, styled by the design system in `assets/css/app.css`
  (PRD §13.2).

  The system is deliberately plain: rules in place of boxes, emphasis by
  weight, everything flush left. There are no icons, rounded corners,
  shadows or transitions, so these components carry none. Class names are
  semantic (`.button`, `.field`, `.flash`); there is no utility framework.
  """
  use Phoenix.Component
  use Gettext, backend: AiInPracticeWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice: a rule and a line of text, no box.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} title="Unavailable">Please try again shortly.</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["flash", "flash-#{@kind}"]}
      {@rest}
    >
      <p :if={@title} class="flash-title">{@title}</p>
      <p>{msg}</p>
      <button type="button" class="flash-close" aria-label={gettext("close")}>
        {gettext("close")}
      </button>
    </div>
    """
  end

  @doc """
  Renders a button, or a link styled as one when `href`, `navigate` or
  `patch` is given. The `primary` variant uses the accent: keep it to one
  per screen.

  ## Examples

      <.button>Send</.button>
      <.button phx-click="go" variant="primary">Begin</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil
  attr :variant, :string, values: [nil, "primary"], default: nil
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, [
        "button",
        assigns.variant && "button-#{assigns.variant}",
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a labelled input with its errors.

  Pass a `Phoenix.HTML.FormField` as `field`, or `name`, `value` and `id`
  directly. Types: `text` and the other HTML input types, `hidden`,
  `checkbox`, `select` and `textarea`.

  ## Examples

      <.input field={@form[:label]} label="Label" />
      <.input name="role" type="select" options={@roles} label="Role group" />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field">
      <label class="field-check">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input type="checkbox" id={@id} name={@name} value="true" checked={@checked} {@rest} />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <div class={!@multiple && "select"}>
        <select
          id={@id}
          name={@name}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <textarea id={@id} name={@name} aria-invalid={@errors != [] && "true"} {@rest}>{Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "Renders a form error message."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="field-error">{render_slot(@inner_block)}</p>
    """
  end

  @doc "Renders a page header with an optional subtitle and actions."
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="page-header">
      <h1>{render_slot(@inner_block)}</h1>
      <p :if={@subtitle != []} class="quiet">{render_slot(@subtitle)}</p>
      <div :if={@actions != []} class="page-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table separated by hairlines.

  ## Examples

      <.table id="links" rows={@links}>
        <:col :let={link} label="status">{link.status}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table">
      <thead>
        <tr>
          <th :for={col <- @col} class="mono">{col[:label]}</th>
          <th :if={@action != []}><span class="visually-hidden">{gettext("actions")}</span></th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td :for={col <- @col}>{render_slot(col, @row_item.(row))}</td>
          <td :if={@action != []}>
            <%= for action <- @action do %>
              {render_slot(action, @row_item.(row))}
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a list of labelled values.

  ## Examples

      <.list>
        <:item title="code">{@version}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="list">
      <%= for item <- @item do %>
        <dt class="mono">{item.title}</dt>
        <dd>{render_slot(item)}</dd>
      <% end %>
    </dl>
    """
  end

  ## JS Commands. No transitions: the design system has no motion.

  def show(js \\ %JS{}, selector), do: JS.show(js, to: selector)

  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(AiInPracticeWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AiInPracticeWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
