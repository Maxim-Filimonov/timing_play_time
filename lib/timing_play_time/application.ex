defmodule TimingPlayTime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    persistence_adapter = Application.fetch_env!(:timing_play_time, :persistence_adapter)

    children =
      [TimingPlayTimeWeb.Telemetry] ++
        persistence_adapter_children(persistence_adapter) ++
        [
          TimingPlayTime.Repo,
          {Ecto.Migrator,
           repos: Application.fetch_env!(:timing_play_time, :ecto_repos),
           skip: skip_migrations?()},
          {DNSCluster,
           query: Application.get_env(:timing_play_time, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: TimingPlayTime.PubSub},
          # Start a worker by calling: TimingPlayTime.Worker.start_link(arg)
          # {TimingPlayTime.Worker, arg},
          # Start to serve requests, typically the last entry
          TimingPlayTimeWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TimingPlayTime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TimingPlayTimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Not every persistence adapter needs a supervised process (e.g. Sqlite is a
  # stateless wrapper around the already-supervised Repo); only start one when
  # the adapter actually implements start_link/1 (as the ETS-backed Stub does).
  defp persistence_adapter_children(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :start_link, 1) do
      [{adapter, []}]
    else
      []
    end
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
