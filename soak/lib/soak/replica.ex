defmodule Soak.Replica do
  @moduledoc """
  The list rebuilt from a watcher's events alone. Each event is logged with
  how long after the item's own update time it arrived.
  """
  use GenServer

  def child_spec(w), do: %{id: {:replica, w.name}, start: {__MODULE__, :start_link, [w]}}
  def start_link(w), do: GenServer.start_link(__MODULE__, w, name: name(w.name))
  def name(watcher), do: :"replica_#{watcher}"
  def items(watcher), do: GenServer.call(name(watcher), :items, 60_000)

  @impl true
  def init(w), do: {:ok, %{w: w, items: %{}, pid: nil, first_at: nil}}

  @impl true
  def handle_call(:items, _from, state), do: {:reply, state.items, state}

  @impl true
  def handle_info({:infusion_watch, pid, event}, state) do
    now = System.monotonic_time(:millisecond)

    # A new watcher process (first start, or a restart): its first events are
    # the whole list again, so the replica starts over from them.
    state =
      if pid != state.pid do
        if state.pid, do: Soak.Log.write(:events, %{watcher: state.w.name, type: "resync", old: inspect(state.pid), new: inspect(pid)})
        %{state | pid: pid, first_at: now, items: %{}}
      else
        state
      end

    initial? = now - state.first_at < 5_000

    items =
      case event.type do
        t when t in [:created, :updated, :entered] -> Map.put(state.items, event.id, event.item)
        :deleted -> Map.delete(state.items, event.id)
        :error -> state.items
      end

    unless initial? and event.type == :created do
      Soak.Log.write(:events, %{
        watcher: state.w.name,
        type: event.type,
        id: event.id,
        changes: event.changes |> Map.keys() |> Enum.map(&to_string/1),
        latency_ms: latency(event),
        error: event.error && Exception.message(event.error)
      })
    end

    {:noreply, %{state | items: items}}
  end

  # From the item's own update time (server clock) to now.
  defp latency(%{type: type, item: item}) when type in [:created, :updated, :entered] do
    stamp = Map.get(item, :updated_at) || Map.get(item, :last_updated)

    with true <- is_binary(stamp),
         {:ok, at, _} <- DateTime.from_iso8601(stamp) do
      DateTime.diff(DateTime.utc_now(), at, :millisecond)
    else
      _ -> nil
    end
  end

  defp latency(_event), do: nil
end
