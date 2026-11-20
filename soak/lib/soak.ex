defmodule Soak do
  @moduledoc false

  # The watcher name of a watcher pid, from the supervisor.
  def watcher_name(pid) do
    case Process.whereis(Soak.Watchers) do
      nil ->
        "unknown"

      _ ->
        Enum.find_value(Supervisor.which_children(Soak.Watchers), "unknown", fn
          {id, ^pid, _, _} -> to_string(id)
          _ -> nil
        end)
    end
  end
end
