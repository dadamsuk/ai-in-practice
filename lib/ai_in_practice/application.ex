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

    # Crash reports must never carry session data (PRD §10).
    AiInPractice.LogRedaction.install()

    children = [
      AiInPracticeWeb.Telemetry,
      AiInPractice.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ai_in_practice, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:ai_in_practice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AiInPractice.PubSub},
      # Live assessment sessions, held only in memory (PRD §10)
      {Registry, keys: :unique, name: AiInPractice.Assessment.Registry},
      {Task.Supervisor, name: AiInPractice.Assessment.TaskSupervisor},
      {DynamicSupervisor,
       name: AiInPractice.Assessment.SessionSupervisor, strategy: :one_for_one},
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
