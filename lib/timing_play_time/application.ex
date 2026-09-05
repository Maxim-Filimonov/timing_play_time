defmodule TimingPlayTime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    persistence_adapter = Application.fetch_env!(:timing_play_time, :persistence_adapter)
    time_source_adapter = Application.fetch_env!(:timing_play_time, :time_source_adapter)
    identity_provider_adapter = Application.fetch_env!(:timing_play_time, :identity_provider_adapter)

    children =
      [TimingPlayTimeWeb.Telemetry, TimingPlayTime.Vault] ++
        supervised_adapter_children(persistence_adapter) ++
        supervised_adapter_children(time_source_adapter) ++
        supervised_adapter_children(identity_provider_adapter) ++
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

  # Not every plug-in adapter needs a supervised process (e.g. Sqlite is a
  # stateless wrapper around the already-supervised Repo); only start one when
  # the adapter has a child_spec/1 to start from (as the ETS-backed
  # Persistence Stub's `use GenServer` and the Auth0 IdentityProvider
  # adapter's own child_spec/1 do — ADR-0015). The IdentityProvider Stub
  # starts nothing, same as the ExMCP-backed Timing adapter.
  defp supervised_adapter_children(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :child_spec, 1) do
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
