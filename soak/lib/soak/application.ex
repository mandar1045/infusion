defmodule Soak.Application do
  @moduledoc """
  A long-running, real-world test of Infusion watchers.

  Each watcher sends its events to a replica, which rebuilds the list from
  events alone. A checker regularly fetches the real list directly and
  compares it with the replica. Everything is logged as JSON lines in data/.
  """
  use Application

  @watchers [
    %{
      name: :vscode_recent,
      sdk: GitHub.Issues,
      fun: :list_for_repo,
      args: ["microsoft", "vscode"],
      params: %{state: "all", sort: "updated", direction: "desc", per_page: 100},
      opts: [every: 30_000, pages: 1],
      complete: false
    },
    %{
      name: :vscode_open_prs,
      sdk: GitHub.Pulls,
      fun: :list,
      args: ["microsoft", "vscode"],
      params: %{state: "open", per_page: 100},
      # Every pull request embeds its repository, which changes on every
      # push: only updated_at decides whether a pull request changed.
      opts: [every: 120_000, pages: 40, version: "updated_at"],
      complete: true,
      check_ignore: [[:base, :repo], [:head, :repo]]
    },
    %{
      name: :elixir_open_issues,
      sdk: GitHub.Issues,
      fun: :list_for_repo,
      args: ["elixir-lang", "elixir"],
      params: %{state: "open", per_page: 100},
      opts: [every: 30_000, pages: 5],
      complete: true
    },
    %{
      name: :phoenix_open_prs,
      sdk: GitHub.Pulls,
      fun: :list,
      args: ["phoenixframework", "phoenix"],
      params: %{state: "open", per_page: 100},
      opts: [every: 60_000, pages: 5, version: "updated_at"],
      complete: true,
      check_ignore: [[:base, :repo], [:head, :repo]]
    },
    %{
      name: :coingecko_top100,
      sdk: CoinGecko.Coins.Markets,
      fun: :list,
      args: [],
      params: %{vs_currency: "usd", order: "market_cap_desc", per_page: 100},
      opts: [every: 60_000, pages: 1],
      complete: false
    }
  ]

  def watchers, do: @watchers

  @impl true
  def start(_type, _args) do
    Soak.Log.attach_telemetry()

    replicas = for w <- @watchers, do: {Soak.Replica, w}

    # The watchers, supervised the way the docs say: the _watch function as
    # the child's start, events to the replica's registered name.
    watchers =
      for w <- @watchers do
        opts = w.opts ++ [to: Soak.Replica.name(w.name), initial: true, async: true]

        %{
          id: w.name,
          start: {w.sdk, :"#{w.fun}_watch", w.args ++ [w.params, opts]},
          restart: :permanent
        }
      end

    children =
      [Soak.Log] ++
        replicas ++
        [
          %{
            id: Soak.Watchers,
            start: {Supervisor, :start_link, [watchers, [strategy: :one_for_one, name: Soak.Watchers, max_restarts: 100, max_seconds: 60]]},
            type: :supervisor
          }
        ] ++
        for(w <- @watchers, do: {Soak.Checker, w}) ++
        [Soak.Metrics]

    Supervisor.start_link(children, strategy: :one_for_one, name: Soak.Supervisor)
  end
end
