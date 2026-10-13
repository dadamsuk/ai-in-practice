defmodule AiInPractice.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    AiInPractice.AdminBind.validate!(
      Application.get_env(:ai_in_practice, :env),
      Application.get_env(:ai_in_practice, AiInPracticeWeb.AdminEndpoint)
    )

    children = [
      AiInPracticeWeb.Telemetry,
      AiInPractice.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ai_in_practice, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:ai_in_practice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AiInPractice.PubSub},
      # Start a worker by calling: AiInPractice.Worker.start_link(arg)
      # {AiInPractice.Worker, arg},
      # Start to serve requests, typically the last entry
      AiInPracticeWeb.Endpoint,
      AiInPracticeWeb.AdminEndpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AiInPractice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AiInPracticeWeb.Endpoint.config_change(changed, removed)
    AiInPracticeWeb.AdminEndpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
