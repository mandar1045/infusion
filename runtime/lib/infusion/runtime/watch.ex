defmodule Infusion.Runtime.Watch do
  @moduledoc """
  Turns any list endpoint into a live feed of changes.

  Most APIs have no webhooks or streams for most of their data, only lists.
  A watcher polls a list, remembers what it saw, and sends you what changed:

      {:ok, watcher} =
        GitHub.Issues.list_for_repo_watch("elixir-lang", "elixir", %{state: "all"}, every: 15_000)

      # in the calling process (a LiveView, a GenServer, IEx):
      receive do
        {:infusion_watch, ^watcher, %Infusion.Runtime.Watch.Event{type: :updated} = event} ->
          event.changes   #=> %{state: {"open", "closed"}, closed_at: {nil, "2026-11-20T..."}}
      end

  Every paginated list function of a generated SDK has a `_watch` variant.

  ## Cheap by design

  Each page is asked for with `If-None-Match` and the `ETag` of the last
  time. Pages that haven't changed come back as an empty `304 Not
  Modified`, and nothing is decoded or compared. GitHub doesn't count a 304
  to an authenticated request against the rate limit, so a watcher on an
  unchanged list is free there. A server's `X-Poll-Interval` is respected as
  the minimum interval.

  ## Events

  `%Infusion.Runtime.Watch.Event{}` with `type` `:created`, `:updated`,
  `:deleted`, `:entered` or `:error`, the item's `id`, the decoded `item` (the last seen
  one for `:deleted`), the `previous` version (for `:updated`), and
  `changes`: `%{field => {old, new}}` for the fields that changed.

  A watcher that reads the whole list (it reaches the last page within
  `:pages`) knows exactly what was created and deleted. A partial view,
  like the first page of issues sorted by update time, can't tell: an item
  that leaves it may just have moved down, so no `:deleted` is sent, and an
  item it hasn't seen before is `:created` only when its creation time
  (`created_at`, `created`, `date_created`, ...) is after the watcher
  started. Otherwise it is `:entered`: an older item that moved into view.

  ## Options

  Any `Infusion.Runtime.Config` setting, plus:

    * `:every`: milliseconds between polls (default 30 seconds)
    * `:to`: where events go: a pid or registered name (default: the
      caller), `{:pubsub, MyApp.PubSub, "topic"}` (broadcast with
      `Phoenix.PubSub`), or a function of one argument, called in the
      watcher. Messages are `{:infusion_watch, watcher_pid, event}`.
    * `:pages`: the most pages read per poll (default 10)
    * `:initial`: send the items already there as `:created` first
      (default `false`: only changes from now on)
    * `:id`: the JSON field that identifies an item (default: what the SDK
      detected, usually `"id"`), or a function of the raw item
    * `:ignore`: fields whose changes alone aren't worth an event, like
      `["updated_at"]`, or paths into them: GitHub's pull requests embed
      their whole repository (`base.repo`, `head.repo`), whose `pushed_at`
      changes on every push to it, so `ignore: ["base.repo", "head.repo"]`
      keeps one push from "changing" every open pull request
    * `:version`: a field that changes whenever the item does, like
      `"updated_at"`: an item then counts as changed only when that field
      changed, and nothing else is compared to decide it
    * `:async`: start without waiting for the first poll (see Supervision)

  ## Supervision

  By default the first poll runs before the `_watch` function returns, so a
  wrong path or credential comes back as `{:error, error}` right away. In a
  supervision tree that would stop your application from starting whenever
  the API is down or rate-limited at boot, so pass `async: true` there: the
  watcher starts at once, and until its first poll succeeds every failure is
  an `:error` event and it tries again at the usual interval.

      children = [
        %{
          id: :elixir_issues,
          start:
            {GitHub.Issues, :list_for_repo_watch,
             ["elixir-lang", "elixir", %{}, [async: true, to: {:pubsub, MyApp.PubSub, "issues"}]]}
        }
      ]

  ## Telemetry

  `[:infusion, :watch, :poll]` after each poll, with `%{duration, pages,
  not_modified, created, updated, deleted, entered}` and `%{operation,
  watcher}`.
  """

  use GenServer

  alias Infusion.Runtime.{Config, Error, Paginate, Schema}

  defmodule Event do
    @moduledoc "A change seen by `Infusion.Runtime.Watch`."
    defstruct [:type, :id, :item, :previous, :operation, :error, changes: %{}]

    @type t :: %__MODULE__{
            type: :created | :updated | :deleted | :entered | :error,
            id: term,
            item: term,
            previous: term,
            changes: %{(atom | String.t()) => {term, term}},
            operation: String.t(),
            error: Infusion.Runtime.Error.t() | nil
          }
  end

  @watch_keys [:every, :to, :pages, :initial, :id, :ignore, :version, :async]
  @max_tracked 50_000

  @doc """
  Starts a watcher on a paginated list `operation`, linked to the caller.
  The first poll runs before this returns, so a wrong path or credential is
  `{:error, error}` here, not a crash later.
  """
  @spec start_link(Config.t(), map, [term], map | keyword, keyword) ::
          {:ok, pid} | {:error, Error.t()}
  def start_link(%Config{} = config, operation, path_args, params, opts \\ []) do
    {watch, call_opts} = Keyword.split(opts, @watch_keys)
    config = Config.merge(config, call_opts)
    pagination = Map.fetch!(operation, :paginate)

    state = %{
      config: config,
      call_opts: call_opts,
      operation: operation,
      pagination: pagination,
      first: Paginate.first_request(operation, path_args, params),
      label: "#{operation.method |> to_string() |> String.upcase()} #{operation.path}",
      every: watch[:every] || 30_000,
      to: watch[:to] || self(),
      pages: watch[:pages] || 10,
      id: watch[:id] || pagination[:id] || "id",
      # ["base.repo"] -> [["base", "repo"]]
      ignore: Enum.map(watch[:ignore] || [], &(&1 |> to_string() |> String.split("."))),
      version: watch[:version] && to_string(watch[:version]),
      etags: %{},
      snapshot: %{},
      # a little earlier than now, for clocks that disagree with the API's
      started_at: DateTime.add(DateTime.utc_now(), -60, :second),
      poll_interval: nil,
      initial?: watch[:initial] == true,
      # false until the first poll succeeded (only with async: true)
      ready?: true
    }

    if watch[:async] do
      GenServer.start_link(__MODULE__, {:async, %{state | ready?: false}})
    else
      case poll(state) do
        {:ok, state, _counts, items} ->
          {state, initial} = baseline(state, items)
          GenServer.start_link(__MODULE__, {state, initial})

        {:error, error, _state} ->
          {:error, error}
      end
    end
  end

  # The first successful poll: what is there now, and the :created events
  # for it when `initial: true`.
  defp baseline(state, items) do
    snapshot = Map.new(items, &{item_id(state, &1), &1})
    initial = if state.initial?, do: Enum.map(items, &event(state, :created, &1, nil)), else: []
    {%{state | snapshot: snapshot, ready?: true}, initial}
  end

  @doc "Stops a watcher."
  @spec stop(pid) :: :ok
  def stop(watcher), do: GenServer.stop(watcher)

  @doc """
  The events of `watcher` as a lazy, endless stream, for scripts and IEx.
  Read it in the process the events are sent to (the one that started the
  watcher, by default).

      {:ok, w} = GitHub.Repos.list_releases_watch("elixir-lang", "elixir")
      w |> Infusion.Runtime.Watch.stream() |> Enum.each(&IO.inspect/1)
  """
  @spec stream(pid) :: Enumerable.t()
  def stream(watcher) do
    Stream.repeatedly(fn ->
      receive do
        {:infusion_watch, ^watcher, event} -> event
      end
    end)
  end

  ## Server

  @impl true
  def init({:async, state}), do: {:ok, state, {:continue, :first_poll}}

  def init({state, initial}) do
    Enum.each(initial, &deliver(state, &1))
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_continue(:first_poll, state), do: {:noreply, first_poll(state)}

  # Until a poll succeeds, failures are :error events and it tries again.
  defp first_poll(state) do
    state =
      case poll(state) do
        {:ok, state, _counts, items} ->
          {state, initial} = baseline(state, items)
          Enum.each(initial, &deliver(state, &1))
          state

        {:error, error, state} ->
          deliver(state, %Event{type: :error, error: error, operation: state.label})
          state
      end

    schedule(state)
    state
  end

  @impl true
  def handle_info(:poll, %{ready?: false} = state), do: {:noreply, first_poll(state)}

  def handle_info(:poll, state) do
    started = System.monotonic_time()

    state =
      case poll(state) do
        {:ok, state, counts, items} ->
          {state, events} = changes(state, items, counts.complete?)
          Enum.each(events, &deliver(state, &1))
          telemetry(state, started, counts, events)
          state

        {:error, error, state} ->
          deliver(state, %Event{type: :error, error: error, operation: state.label})
          state
      end

    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    every = max(state.every, (state.poll_interval || 0) * 1000)
    Process.send_after(self(), :poll, every)
  end

  ## Polling

  # Reads up to `pages` pages, each conditionally. Returns every raw item
  # and whether the whole list was read.
  defp poll(state), do: poll_pages(state, state.first, 1, [], %{pages: 0, not_modified: 0})

  defp poll_pages(state, request, n, acc, counts) do
    key = page_key(request)
    {etag, cached} = Map.get(state.etags, key, {nil, nil})
    opts = conditional(state.call_opts, etag)

    case Paginate.fetch(state.config, request, opts) do
      {:ok, response} ->
        {raw, next} = Paginate.page(response, request, state.pagination)
        state = remember(state, key, response, {raw, next})
        continue(state, next, n, acc ++ raw, %{counts | pages: counts.pages + 1})

      {:error, %Error{status: 304} = error} when cached != nil ->
        {raw, next} = cached
        state = %{state | poll_interval: poll_interval(error.headers) || state.poll_interval}
        counts = %{counts | pages: counts.pages + 1, not_modified: counts.not_modified + 1}
        continue(state, next, n, acc ++ raw, counts)

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp continue(state, {:fetch, request}, n, acc, counts) when n < state.pages,
    do: poll_pages(state, request, n + 1, acc, counts)

  defp continue(state, next, _n, acc, counts),
    do: {:ok, state, Map.put(counts, :complete?, next == :done), acc}

  defp conditional(opts, nil), do: opts

  defp conditional(opts, etag),
    do:
      Keyword.update(
        opts,
        :headers,
        [{"if-none-match", etag}],
        &(&1 ++ [{"if-none-match", etag}])
      )

  defp remember(state, key, response, page) do
    state = %{state | poll_interval: poll_interval(response.headers) || state.poll_interval}

    case Req.Response.get_header(response, "etag") do
      [etag | _] -> %{state | etags: Map.put(state.etags, key, {etag, page})}
      [] -> %{state | etags: Map.delete(state.etags, key)}
    end
  end

  defp poll_interval(headers) do
    with [value | _] <- Map.get(headers || %{}, "x-poll-interval", []),
         {seconds, ""} <- Integer.parse(value) do
      seconds
    else
      _ -> nil
    end
  end

  defp page_key(request),
    do: {request.operation[:url], request.path_args, Enum.sort(request.params)}

  ## Comparing

  defp changes(state, items, complete?) do
    current = Map.new(items, &{item_id(state, &1), &1})

    {events, _} =
      Enum.flat_map_reduce(items, MapSet.new(), fn raw, seen ->
        id = item_id(state, raw)

        cond do
          MapSet.member?(seen, id) ->
            {[], seen}

          not Map.has_key?(state.snapshot, id) ->
            {[event(state, new_type(state, raw, complete?), raw, nil)], MapSet.put(seen, id)}

          changed?(state, state.snapshot[id], raw) ->
            ev = event(state, :updated, raw, state.snapshot[id])
            {if(ev.changes == %{}, do: [], else: [ev]), MapSet.put(seen, id)}

          true ->
            {[], MapSet.put(seen, id)}
        end
      end)

    deleted =
      if complete? do
        for {id, raw} <- state.snapshot,
            not Map.has_key?(current, id),
            do: event(state, :deleted, raw, nil)
      else
        []
      end

    # A partial view keeps what scrolled out of it, to know it when it comes back.
    snapshot = if complete?, do: current, else: cap(Map.merge(state.snapshot, current))
    {%{state | snapshot: snapshot}, events ++ deleted}
  end

  # An item the watcher hasn't seen. Reading the whole list, it is new. In a
  # partial view (the first page of issues sorted by update time) it may be
  # an old item that moved in: it is :created only when its creation time
  # says so, else :entered.
  defp new_type(_state, _raw, true), do: :created

  defp new_type(state, raw, false) do
    case created_at(raw) do
      %DateTime{} = at ->
        if DateTime.compare(at, state.started_at) != :lt, do: :created, else: :entered

      nil ->
        :entered
    end
  end

  @created_fields ~w(created_at created date_created createdAt creation_time inserted_at)
  defp created_at(raw) when is_map(raw) do
    Enum.find_value(@created_fields, fn field -> timestamp(Map.get(raw, field)) end)
  end

  defp created_at(_raw), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        at

      _ ->
        # RFC 2822, as Twilio writes dates: "Fri, 20 Nov 2026 14:21:35 +0000"
        case Regex.run(
               ~r/^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) \+0000$/,
               value
             ) do
          [_, d, mon, y, h, m, sec] ->
            month =
              Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == mon))

            with true <- month != nil,
                 {:ok, date} <- Date.new(String.to_integer(y), month + 1, String.to_integer(d)),
                 {:ok, time} <-
                   Time.new(String.to_integer(h), String.to_integer(m), String.to_integer(sec)),
                 {:ok, at} <- DateTime.new(date, time) do
              at
            else
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  # Unix seconds (Stripe), or milliseconds.
  defp timestamp(value) when is_integer(value) and value > 100_000_000_000,
    do: DateTime.from_unix!(div(value, 1000))

  defp timestamp(value) when is_integer(value) and value > 100_000_000,
    do: DateTime.from_unix!(value)

  defp timestamp(_value), do: nil

  defp cap(snapshot) when map_size(snapshot) <= @max_tracked, do: snapshot
  defp cap(snapshot), do: snapshot |> Enum.take(@max_tracked) |> Map.new()

  defp event(state, type, raw, previous_raw) do
    item_type = state.pagination[:item]
    item = Schema.decode(raw, item_type)
    previous = previous_raw && Schema.decode(previous_raw, item_type)

    %Event{
      type: type,
      id: item_id(state, raw),
      item: item,
      previous: previous,
      changes:
        if(type == :updated, do: diff(state, previous_raw, raw, previous, item), else: %{}),
      operation: state.label
    }
  end

  # With `version`, only that field says whether an item changed; otherwise
  # any difference outside the ignored paths does.
  defp changed?(%{version: field}, old, new)
       when is_binary(field) and is_map(old) and is_map(new),
       do: Map.get(old, field) != Map.get(new, field)

  defp changed?(state, old, new), do: strip(old, state.ignore) != strip(new, state.ignore)

  # The item without the ignored paths: ["base", "repo"] drops raw["base"]["repo"].
  defp strip(raw, []), do: raw
  defp strip(raw, paths) when is_map(raw), do: Enum.reduce(paths, raw, &drop_path(&2, &1))
  defp strip(raw, _paths), do: raw

  defp drop_path(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp drop_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, child} when is_map(child) -> Map.put(map, key, drop_path(child, rest))
      _ -> map
    end
  end

  defp drop_path(other, _path), do: other

  # %{field => {old, new}}: struct fields by their atom, with decoded values;
  # fields the SDK doesn't know by their JSON name, with raw values. Fields
  # that differ only in ignored paths aren't listed.
  defp diff(state, old_raw, new_raw, old, new) when is_map(old_raw) and is_map(new_raw) do
    stripped_old = strip(old_raw, state.ignore)
    stripped_new = strip(new_raw, state.ignore)

    names =
      (Map.keys(stripped_old) ++ Map.keys(stripped_new))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(stripped_old, &1) != Map.get(stripped_new, &1)))

    fields = fields(new)

    Map.new(names, fn name ->
      case fields[name] do
        nil -> {name, {Map.get(old_raw, name), Map.get(new_raw, name)}}
        field -> {field, {Map.get(old, field), Map.get(new, field)}}
      end
    end)
  end

  defp diff(_state, old_raw, new_raw, _old, _new), do: %{value: {old_raw, new_raw}}

  defp fields(%module{}) do
    if function_exported?(module, :__schema__, 1),
      do: Map.new(module.__schema__(:fields), fn {field, name, _} -> {name, field} end),
      else: %{}
  end

  defp fields(_item), do: %{}

  defp item_id(%{id: fun}, raw) when is_function(fun, 1), do: fun.(raw)

  defp item_id(%{id: key}, raw) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, id} when id != nil -> id
      _ -> {:hash, :erlang.phash2(raw)}
    end
  end

  defp item_id(_state, raw), do: {:hash, :erlang.phash2(raw)}

  ## Delivering

  defp deliver(%{to: fun}, event) when is_function(fun, 1), do: fun.(event)

  defp deliver(%{to: {:pubsub, pubsub, topic}}, event),
    # credo:disable-for-next-line
    do: apply(Phoenix.PubSub, :broadcast, [pubsub, topic, {:infusion_watch, self(), event}])

  defp deliver(%{to: to}, event), do: send(to, {:infusion_watch, self(), event})

  defp telemetry(state, started, counts, events) do
    by_type = Enum.frequencies_by(events, & &1.type)

    :telemetry.execute(
      [:infusion, :watch, :poll],
      %{
        duration: System.monotonic_time() - started,
        pages: counts.pages,
        not_modified: counts.not_modified,
        created: by_type[:created] || 0,
        updated: by_type[:updated] || 0,
        deleted: by_type[:deleted] || 0,
        entered: by_type[:entered] || 0
      },
      %{operation: state.label, watcher: self()}
    )
  end
end
