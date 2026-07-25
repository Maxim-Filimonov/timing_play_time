defmodule TimingPlayTime.Plugins.Persistence.Stub do
  @moduledoc """
  Stub implementation of Persistence for development and testing.

  Uses ETS tables for in-memory storage without requiring Fibery MCP integration.
  """

  use GenServer
  @behaviour TimingPlayTime.Plugins.Persistence

  @activities_table :stub_activities
  @manual_sync_table :stub_manual_sync
  @playtime_used_table :stub_playtime_used

  # Client API

  def clear_all_state do
    GenServer.call(__MODULE__, :clear_all_state)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def list_activities do
    GenServer.call(__MODULE__, :list_activities)
  end

  @impl true
  def get_activity(id) do
    GenServer.call(__MODULE__, {:get_activity, id})
  end

  @impl true
  def create_activity(attrs) do
    GenServer.call(__MODULE__, {:create_activity, attrs})
  end

  @impl true
  def update_activity(id, attrs) do
    GenServer.call(__MODULE__, {:update_activity, id, attrs})
  end

  @impl true
  def delete_activity(id) do
    GenServer.call(__MODULE__, {:delete_activity, id})
  end

  @impl true
  def get_manual_sync_total do
    GenServer.call(__MODULE__, :get_manual_sync_total)
  end

  @impl true
  def set_manual_sync_total(minutes) do
    GenServer.call(__MODULE__, {:set_manual_sync_total, minutes})
  end

  @impl true
  def log_playtime_used(minutes, logged_at \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:log_playtime_used, minutes, logged_at})
  end

  @impl true
  def list_playtime_used do
    GenServer.call(__MODULE__, :list_playtime_used)
  end

  @impl true
  def total_playtime_used do
    GenServer.call(__MODULE__, :total_playtime_used)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@activities_table, [:named_table, :set, :public])
    :ets.new(@manual_sync_table, [:named_table, :set, :public])
    :ets.new(@playtime_used_table, [:named_table, :ordered_set, :public])

    # Initialize manual sync to 0
    :ets.insert(@manual_sync_table, {:total, 0.0})

    {:ok, %{}}
  end

  @impl true
  def handle_call(:list_activities, _from, state) do
    activities =
      @activities_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, activity} -> activity end)

    {:reply, {:ok, activities}, state}
  end

  @impl true
  def handle_call({:get_activity, id}, _from, state) do
    case :ets.lookup(@activities_table, id) do
      [{^id, activity}] -> {:reply, {:ok, activity}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:create_activity, attrs}, _from, state) do
    id = generate_id()
    activated_at = Map.get(attrs, :activated_at, DateTime.utc_now())

    activity = %{
      id: id,
      name: Map.fetch!(attrs, :name),
      time_source_identifier: Map.fetch!(attrs, :time_source_identifier),
      multiplier: Map.fetch!(attrs, :multiplier),
      activated_at: activated_at
    }

    :ets.insert(@activities_table, {id, activity})
    {:reply, {:ok, activity}, state}
  end

  @impl true
  def handle_call({:update_activity, id, attrs}, _from, state) do
    case :ets.lookup(@activities_table, id) do
      [{^id, activity}] ->
        updated_activity = Map.merge(activity, attrs)
        :ets.insert(@activities_table, {id, updated_activity})
        {:reply, {:ok, updated_activity}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_activity, id}, _from, state) do
    :ets.delete(@activities_table, id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_manual_sync_total, _from, state) do
    [{:total, minutes}] = :ets.lookup(@manual_sync_table, :total)
    {:reply, {:ok, minutes}, state}
  end

  @impl true
  def handle_call({:set_manual_sync_total, minutes}, _from, state) do
    :ets.insert(@manual_sync_table, {:total, minutes})
    {:reply, {:ok, minutes}, state}
  end

  @impl true
  def handle_call({:log_playtime_used, minutes, logged_at}, _from, state) do
    id = generate_id()

    usage = %{
      id: id,
      minutes: minutes,
      logged_at: logged_at
    }

    :ets.insert(@playtime_used_table, {id, usage})
    {:reply, {:ok, usage}, state}
  end

  @impl true
  def handle_call(:list_playtime_used, _from, state) do
    usages =
      @playtime_used_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, usage} -> usage end)

    {:reply, {:ok, usages}, state}
  end

  @impl true
  def handle_call(:total_playtime_used, _from, state) do
    total =
      @playtime_used_table
      |> :ets.tab2list()
      |> Enum.reduce(0.0, fn {_id, usage}, acc -> acc + usage.minutes end)

    {:reply, {:ok, total}, state}
  end

  @impl true
  def handle_call(:clear_all_state, _from, state) do
    :ets.delete_all_objects(@activities_table)
    :ets.delete_all_objects(@manual_sync_table)
    :ets.delete_all_objects(@playtime_used_table)
    :ets.insert(@manual_sync_table, {:total, 0.0})
    {:reply, :ok, state}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
