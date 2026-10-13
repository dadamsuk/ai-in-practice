defmodule AiInPracticeWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use AiInPracticeWeb, :controller
      use AiInPracticeWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller, do: controller(verified_routes())

  # Controllers, views and LiveViews on the admin endpoint, whose ~p paths are
  # verified against the admin router.
  def admin_controller, do: controller(admin_verified_routes())
  def admin_html, do: html(admin_verified_routes())
  def admin_live_view, do: live_view(admin_verified_routes())

  defp controller(routes) do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: AiInPracticeWeb.Gettext

      import Plug.Conn

      unquote(routes)
    end
  end

  def live_view, do: live_view(verified_routes())

  defp live_view(routes) do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers(routes))
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers(verified_routes()))
    end
  end

  def html, do: html(verified_routes())

  defp html(routes) do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers(routes))
    end
  end

  defp html_helpers(routes) do
    quote do
      # Translation
      use Gettext, backend: AiInPracticeWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import AiInPracticeWeb.CoreComponents

      # Common modules used in templates
      alias AiInPracticeWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(routes)
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AiInPracticeWeb.Endpoint,
        router: AiInPracticeWeb.Router,
        statics: AiInPracticeWeb.static_paths()
    end
  end

  def admin_verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AiInPracticeWeb.AdminEndpoint,
        router: AiInPracticeWeb.AdminRouter,
        statics: AiInPracticeWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
