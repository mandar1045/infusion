defmodule Infusion.Runtime.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Infusion.Runtime.Drift],
      strategy: :one_for_one,
      name: Infusion.Runtime.Supervisor
    )
  end
end
