defmodule Soak.Checker do
  @moduledoc """
  Fetches the real list directly (not through the watcher) and compares it
  with the replica. A difference seen in two checks in a row, while the
  real item stayed the same, is a missed change: `persistent`. Others are
  timing (the list changed between the watcher's poll and this fetch).
  """
  use GenServer

  def child_spec(w), do: %{id: {:checker, w.name}, start: {__MODULE__, :start_link, [w]}}
  def start_link(w), do: GenServer.start_link(__MODULE__, w)

  @impl true
  def init(w) do
    first = String.to_integer(System.get_env("SOAK_FIRST_CHECK_MS", "300000"))
    Process.send_after(self(), :check, first + :rand.uniform(30_000))
    {:ok, %{w: w, prev: %{}}}
  end

  @impl true
  def handle_info(:check, %{w: w} = state) do
    every = String.to_integer(System.get_env("SOAK_CHECK_MS", "600000"))
    Process.send_after(self(), :check, every)

    started = System.monotonic_time(:millisecond)

    state =
      case fetch(w) do
        {:ok, fresh} -> compare(state, fresh, System.monotonic_time(:millisecond) - started)
        {:error, error} ->
          Soak.Log.write(:checks, %{watcher: w.name, error: Exception.message(error)})
          state
      end

    {:noreply, state}
  rescue
    e ->
      Soak.Log.write(:checks, %{watcher: state.w.name, error: Exception.message(e)})
      {:noreply, state}
  end

  defp fetch(%{complete: true} = w) do
    with {:ok, stream} <- apply(w.sdk, :"#{w.fun}_all", w.args ++ [w.params]),
         do: {:ok, Enum.to_list(stream)}
  end

  defp fetch(w), do: apply(w.sdk, w.fun, w.args ++ [w.params])

  defp compare(state, fresh, fetch_ms) do
    w = state.w
    ignore = Map.get(w, :check_ignore, [])
    replica = Map.new(Soak.Replica.items(w.name), fn {id, item} -> {id, strip(item, ignore)} end)
    fresh_map = Map.new(fresh, &{&1.id, strip(&1, ignore)})

    missing = for {id, item} <- fresh_map, not Map.has_key?(replica, id), into: %{}, do: {id, {:missing, data(item)}}

    changed =
      for {id, item} <- fresh_map, Map.has_key?(replica, id), data(replica[id]) != data(item), into: %{} do
        {id, {:changed, data(item)}}
      end

    extra =
      if w.complete,
        do: for({id, _} <- replica, not Map.has_key?(fresh_map, id), into: %{}, do: {id, {:extra, nil}}),
        else: %{}

    now = Map.merge(missing, changed) |> Map.merge(extra)
    persistent = for {id, d} <- now, Map.get(state.prev, id) == d, do: {id, d}

    Soak.Log.write(:checks, %{
      watcher: w.name,
      fetch_ms: fetch_ms,
      fresh: map_size(fresh_map),
      replica: map_size(replica),
      missing: map_size(missing),
      changed: map_size(changed),
      extra: map_size(extra),
      persistent: length(persistent),
      persistent_details:
        Enum.map(persistent, fn {id, {kind, item}} ->
          %{id: id, kind: kind, fields: if(kind == :changed, do: differing(replica[id], item), else: [])}
        end)
    })

    %{state | prev: now}
  end

  # Paths the watcher was told to ignore don't count here either.
  defp strip(item, paths), do: Enum.reduce(paths, item, &drop(&2, &1))

  defp drop(item, [key]) when is_map(item), do: Map.put(item, key, nil)

  defp drop(item, [key | rest]) when is_map(item) do
    case Map.get(item, key) do
      child when is_map(child) -> Map.put(item, key, drop(child, rest))
      _ -> item
    end
  end

  defp drop(item, _), do: item

  defp data(%_{} = item), do: item |> Map.from_struct() |> Map.delete(:__present__)
  defp data(item), do: item

  defp differing(old, new) when is_map(old) and is_map(new) do
    old = data(old)
    for {k, v} <- new, Map.get(old, k) != v, do: to_string(k)
  end

  defp differing(_, _), do: []
end
