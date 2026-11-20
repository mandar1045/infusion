defmodule Soak.Log do
  @moduledoc "Appends JSON lines to data/<kind>.jsonl, and records telemetry."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def write(kind, map) do
    line = map |> Map.put(:t, DateTime.utc_now() |> DateTime.to_iso8601()) |> Jason.encode!()
    GenServer.cast(__MODULE__, {:write, kind, line})
  end

  @impl true
  def init(:ok) do
    File.mkdir_p!(dir())
    write(:runs, %{event: "start", node: inspect(node())})
    {:ok, %{files: %{}, requests: %{}}, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state) do
    Process.send_after(self(), :flush_requests, 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:write, kind, line}, state) do
    {file, state} = file(state, kind)
    IO.binwrite(file, [line, "\n"])
    {:noreply, state}
  end

  def handle_cast({:request, key}, state) do
    {:noreply, update_in(state.requests, &Map.update(&1, key, 1, fn n -> n + 1 end))}
  end

  @impl true
  def handle_info(:flush_requests, state) do
    for {{host, status}, n} <- state.requests do
      line = Jason.encode!(%{t: DateTime.utc_now() |> DateTime.to_iso8601(), host: host, status: status, count: n})
      {file, _} = file(state, :requests)
      IO.binwrite(file, [line, "\n"])
    end

    Process.send_after(self(), :flush_requests, 60_000)
    {:noreply, %{state | requests: %{}}}
  end

  defp file(state, kind) do
    case state.files[kind] do
      nil ->
        {:ok, f} = File.open(Path.join(dir(), "#{kind}.jsonl"), [:append, :binary])
        {f, put_in(state.files[kind], f)}

      f ->
        {f, state}
    end
  end

  def dir, do: Path.expand("../../data", __DIR__)

  def attach_telemetry do
    :telemetry.attach("soak-poll", [:infusion, :watch, :poll], &__MODULE__.on_poll/4, nil)
    :telemetry.attach("soak-request", [:infusion, :request, :stop], &__MODULE__.on_request/4, nil)
  end

  def on_poll(_event, m, meta, _) do
    write(:polls, %{
      watcher: Soak.watcher_name(meta.watcher),
      duration_ms: System.convert_time_unit(m.duration, :native, :millisecond),
      pages: m.pages,
      not_modified: m.not_modified,
      created: m.created,
      updated: m.updated,
      deleted: m.deleted,
      entered: Map.get(m, :entered, 0)
    })
  end

  def on_request(_event, _m, meta, _) do
    host = URI.parse(meta.url).host
    status = meta[:status] || inspect(meta[:error] && meta.error.__struct__)
    GenServer.cast(__MODULE__, {:request, {host, status}})
  end
end
