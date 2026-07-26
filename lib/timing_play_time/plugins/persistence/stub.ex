defmodule TimingPlayTime.Plugins.Persistence.Stub do
  @moduledoc """
  Stub implementation of Persistence for development and testing.

  Uses ETS tables for in-memory storage without requiring Fibery MCP integration.

  Every function is scoped to a `user_id` (ADR-0006); a row belonging to a
  different user is treated the same as a missing one.
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
  def list_activities(user_id) do
    GenServer.call(__MODULE__, {:list_activities, user_id})
  end

  @impl true
  def get_activity(user_id, id) do
    GenServer.call(__MODULE__, {:get_activity, user_id, id})
  end

  @impl true
  def create_activity(user_id, attrs) do
    GenServer.call(__MODULE__, {:create_activity, user_id, attrs})
  end

  @impl true
  def update_activity(user_id, id, attrs) do
    GenServer.call(__MODULE__, {:update_activity, user_id, id, attrs})
  end

  @impl true
  def delete_activity(user_id, id) do
    GenServer.call(__MODULE__, {:delete_activity, user_id, id})
  end

  @impl true
  def get_manual_sync_total(user_id) do
    GenServer.call(__MODULE__, {:get_manual_sync_total, user_id})
  end

  @impl true
  def set_manual_sync_total(user_id, minutes) do
    GenServer.call(__MODULE__, {:set_manual_sync_total, user_id, minutes})
  end

  @impl true
  def log_playtime_used(user_id, minutes, logged_at \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:log_playtime_used, user_id, minutes, logged_at})
  end

  @impl true
  def list_playtime_used(user_id) do
    GenServer.call(__MODULE__, {:list_playtime_used, user_id})
  end

  @impl true
  def total_playtime_used(user_id) do
    GenServer.call(__MODULE__, {:total_playtime_used, user_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@activities_table, [:named_table, :set, :public])
    :ets.new(@manual_sync_table, [:named_table, :bag, :public])
    :ets.new(@playtime_used_table, [:named_table, :ordered_set, :public])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:list_activities, user_id}, _from, state) do
    activities =
      @activities_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, activity} -> activity end)
      |> Enum.filter(&(&1.user_id == user_id))

    {:reply, {:ok, activities}, state}
  end

  @impl true
  def handle_call({:get_activity, user_id, id}, _from, state) do
    case :ets.lookup(@activities_table, id) do
      [{^id, %{user_id: ^user_id} = activity}] -> {:reply, {:ok, activity}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:create_activity, user_id, attrs}, _from, state) do
    id = generate_id()
    activated_at = Map.get(attrs, :activated_at, DateTime.utc_now())

    activity = %{
      id: id,
      name: Map.fetch!(attrs, :name),
      time_source_identifier: Map.fetch!(attrs, :time_source_identifier),
      multiplier: Map.fetch!(attrs, :multiplier),
      activated_at: activated_at,
      user_id: user_id
    }

    :ets.insert(@activities_table, {id, activity})
    {:reply, {:ok, activity}, state}
  end

  @impl true
  def handle_call({:update_activity, user_id, id, attrs}, _from, state) do
    case :ets.lookup(@activities_table, id) do
      [{^id, %{user_id: ^user_id} = activity}] ->
        updated_activity = Map.merge(activity, attrs)
        :ets.insert(@activities_table, {id, updated_activity})
        {:reply, {:ok, updated_activity}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_activity, user_id, id}, _from, state) do
    case :ets.lookup(@activities_table, id) do
      [{^id, %{user_id: ^user_id}}] -> :ets.delete(@activities_table, id)
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_manual_sync_total, user_id}, _from, state) do
    minutes =
      case :ets.lookup(@manual_sync_table, user_id) do
        [] -> 0.0
        entries -> entries |> Enum.max_by(fn {_user_id, _minutes, at} -> at end) |> elem(1)
      end

    {:reply, {:ok, minutes}, state}
  end

  @impl true
  def handle_call({:set_manual_sync_total, user_id, minutes}, _from, state) do
    :ets.insert(@manual_sync_table, {user_id, minutes, System.monotonic_time()})
    {:reply, {:ok, minutes}, state}
  end

  @impl true
  def handle_call({:log_playtime_used, user_id, minutes, logged_at}, _from, state) do
    id = generate_id()

    usage = %{
      id: id,
      minutes: minutes,
      logged_at: logged_at,
      user_id: user_id
    }

    :ets.insert(@playtime_used_table, {id, usage})
    {:reply, {:ok, usage}, state}
  end

  @impl true
  def handle_call({:list_playtime_used, user_id}, _from, state) do
    usages =
      @playtime_used_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, usage} -> usage end)
      |> Enum.filter(&(&1.user_id == user_id))

    {:reply, {:ok, usages}, state}
  end

  @impl true
  def handle_call({:total_playtime_used, user_id}, _from, state) do
    total =
      @playtime_used_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, usage} -> usage end)
      |> Enum.filter(&(&1.user_id == user_id))
      |> Enum.reduce(0.0, fn usage, acc -> acc + usage.minutes end)

    {:reply, {:ok, total}, state}
  end

  @impl true
  def handle_call(:clear_all_state, _from, state) do
    :ets.delete_all_objects(@activities_table)
    :ets.delete_all_objects(@manual_sync_table)
    :ets.delete_all_objects(@playtime_used_table)
    {:reply, :ok, state}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
