defmodule AiInPracticeWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import AiInPracticeWeb.CoreComponents

  # Drop the root-tag marker LiveView adds, to keep assertions readable.
  defp html(fun, assigns \\ %{}),
    do: fun.(assigns) |> rendered_to_string() |> String.replace(" phx-r", "")

  defp form_for(params, errors \\ []) do
    to_form(params, as: :link, errors: errors, action: :validate)
  end

  describe "flash/1" do
    test "renders a message from the flash, with title and close" do
      assigns = %{flash: %{"error" => "Temporarily unavailable"}}

      out =
        html(
          fn assigns ->
            ~H"""
            <.flash kind={:error} title="Sorry" flash={@flash} />
            """
          end,
          assigns
        )

      assert out =~ ~s(class="flash flash-error")
      assert out =~ ~s(role="alert")
      assert out =~ "Sorry"
      assert out =~ "Temporarily unavailable"
      assert out =~ ">\n    close\n"
    end

    test "renders nothing when there is no message" do
      out =
        html(fn assigns ->
          ~H"""
          <.flash kind={:info} flash={%{}} />
          """
        end)

      refute out =~ "flash-info"
    end
  end

  describe "button/1" do
    test "renders a button, with the primary variant" do
      out =
        html(fn assigns ->
          ~H"""
          <.button>Plain</.button>
          <.button variant="primary" type="submit">Begin</.button>
          """
        end)

      assert out =~ ~r/<button class="button">\s*Plain/
      assert out =~ ~r/<button class="button button-primary" type="submit">\s*Begin/
    end

    test "renders a link styled as a button when given a destination" do
      out =
        html(fn assigns ->
          ~H"""
          <.button navigate="/next">Next</.button>
          """
        end)

      assert out =~ ~s(href="/next")
      assert out =~ ~s(class="button")
      refute out =~ "<button"
    end
  end

  describe "input/1" do
    test "a text field from a form, with label and value" do
      assigns = %{form: form_for(%{"label" => "IND-014"})}

      out =
        html(
          fn assigns ->
            ~H"""
            <.input field={@form[:label]} label="Label" />
            """
          end,
          assigns
        )

      assert out =~ ~s(<label for="link_label" class="field-label">Label</label>)
      assert out =~ ~s(name="link[label]")
      assert out =~ ~s(value="IND-014")
      refute out =~ "aria-invalid"
    end

    test "shows translated errors on a used field" do
      assigns = %{
        form: form_for(%{"quota" => "-1"}, quota: {"must be greater than %{number}", [number: 0]})
      }

      out =
        html(
          fn assigns ->
            ~H"""
            <.input field={@form[:quota]} type="number" label="Quota" />
            """
          end,
          assigns
        )

      assert out =~ ~s(aria-invalid="true")
      assert out =~ ~s(<p class="field-error">must be greater than 0</p>)
    end

    test "a multiple select gets a list name" do
      assigns = %{form: form_for(%{"roles" => ["finance"]})}

      out =
        html(
          fn assigns ->
            ~H"""
            <.input field={@form[:roles]} type="select" multiple options={["finance", "people"]} />
            """
          end,
          assigns
        )

      assert out =~ ~s(name="link[roles][]")
      assert out =~ ~s(<option selected value="finance">finance</option>)
    end

    test "hidden, checkbox, select, textarea and plain inputs" do
      out =
        html(fn assigns ->
          ~H"""
          <.input name="h" type="hidden" value="x" />
          <.input name="agree" type="checkbox" value="true" label="I agree" />
          <.input
            name="role"
            type="select"
            label="Role group"
            prompt="Choose"
            options={[{"Finance", "finance"}]}
            value="finance"
          />
          <.input name="answer" type="textarea" label="Answer" value="Some text" />
          <.input name="email" id="email" type="email" value="a@b.c" errors={["is wrong"]} />
          """
        end)

      assert out =~ ~s(<input type="hidden" name="h" value="x">)
      assert out =~ ~r/<input type="checkbox" name="agree" value="true" checked>/
      assert out =~ "I agree"
      assert out =~ ~s(<option value="">Choose</option>)
      assert out =~ ~s(<option selected value="finance">Finance</option>)
      assert out =~ ~r/<textarea[^>]*name="answer"[^>]*>\s*Some text<\/textarea>/
      assert out =~ ~s(type="email")
      assert out =~ "is wrong"
    end
  end

  test "header/1 renders title, subtitle and actions" do
    out =
      html(fn assigns ->
        ~H"""
        <.header>
          Links
          <:subtitle>Issued over Tailscale</:subtitle>
          <:actions><.button>New</.button></:actions>
        </.header>
        """
      end)

    assert out =~ ~r/<h1>\s*Links\s*<\/h1>/
    assert out =~ "Issued over Tailscale"
    assert out =~ ~s(class="page-actions")
  end

  test "table/1 renders columns, rows and actions" do
    assigns = %{rows: [%{id: 1, status: "unused"}, %{id: 2, status: "completed"}]}

    out =
      html(
        fn assigns ->
          ~H"""
          <.table id="links" rows={@rows} row_id={&"link-#{&1.id}"}>
            <:col :let={row} label="status">{row.status}</:col>
            <:action :let={row}>revoke {row.id}</:action>
          </.table>
          """
        end,
        assigns
      )

    assert out =~ ~s(<th class="mono">status</th>)
    assert out =~ ~s(id="link-1")
    assert out =~ "completed"
    assert out =~ "revoke 2"
  end

  test "list/1 renders labelled values" do
    out =
      html(fn assigns ->
        ~H"""
        <.list>
          <:item title="code">abc1234</:item>
        </.list>
        """
      end)

    assert out =~ ~s(<dt class="mono">code</dt>)
    assert out =~ "abc1234"
  end

  test "show/2 and hide/2 build JS commands without transitions" do
    assert %Phoenix.LiveView.JS{ops: [["show", %{to: "#x"}]]} = show("#x")
    assert %Phoenix.LiveView.JS{ops: [["hide", %{to: "#x"}]]} = hide("#x")
  end

  test "translate_error/1 handles plurals and translate_errors/2 picks a field" do
    assert translate_error({"should be at least %{count} character(s)", [count: 3]}) =~ "3"

    errors = [quota: {"is invalid", []}, label: {"can't be blank", []}]
    assert translate_errors(errors, :label) == ["can't be blank"]
  end
end
