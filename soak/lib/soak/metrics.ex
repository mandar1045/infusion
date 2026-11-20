defmodule Soak.Metrics do
  @moduledoc "Memory and process counts every minute; GitHub's rate-limit counter every 5 minutes."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    send(self(), :vm)
    send(self(), :rate)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:vm, state) do
    watchers =
      for {id, pid, _, _} <- Supervisor.which_children(Soak.Watchers), is_pid(pid), into: %{} do
        {id, (Process.info(pid, :memory) || {:memory, 0}) |> elem(1)}
      end

    Soak.Log.write(:metrics, %{
      kind: "vm",
      memory_total: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count),
      watcher_memory: watchers
    })

    Process.send_after(self(), :vm, 60_000)
    {:noreply, state}
  end

  def handle_info(:rate, state) do
    case GitHub.RateLimit.get() do
      {:ok, %{resources: %{core: core}}} ->
        Soak.Log.write(:metrics, %{kind: "github_rate", used: core.used, remaining: core.remaining, reset: core.reset})

      {:error, e} ->
        Soak.Log.write(:metrics, %{kind: "github_rate", error: Exception.message(e)})
    end

    Process.send_after(self(), :rate, 300_000)
    {:noreply, state}
  end
end
