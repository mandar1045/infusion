defmodule Infusion.Runtime.WatchTest do
  # The watcher polls from its own process: the stub is shared.
  use ExUnit.Case, async: false
  alias Infusion.Runtime.{Config, Watch}
  alias Infusion.Runtime.Watch.Event

  defmodule Issue do
    defstruct [:id, :title, :state, :updated_at, __extra__: %{}, __present__: []]

    def __schema__(:fields),
      do: [
        {:id, "id", :integer},
        {:title, "title", :string},
        {:state, "state", :string},
        {:updated_at, "updated_at", :string}
      ]
  end

  @op %{
    method: :get,
    path: "/issues",
    params: [{:page, "page", :query}, {:per_page, "per_page", :query}],
    response: {:array, {:ref, Issue}},
    paginate: %{
      style: :page,
      param: "page",
      per_page: "per_page",
      items: [],
      item: {:ref, Issue},
      id: "id"
    }
  }

  # A fake API: a list of issues, paged by ?page=&per_page=, with real ETags
  # and 304s. Counts what it served.
  setup do
    Req.Test.set_req_test_to_shared()

    {:ok, api} =
      Agent.start_link(fn -> %{issues: [], served: %{200 => 0, 304 => 0}, poll: nil} end)

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = String.to_integer(conn.query_params["page"] || "1")
      per_page = String.to_integer(conn.query_params["per_page"] || "100")
      %{issues: issues, poll: poll} = Agent.get(api, & &1)
      items = issues |> Enum.drop((page - 1) * per_page) |> Enum.take(per_page)
      etag = ~s("#{:erlang.phash2(items)}")
      conn = if poll, do: Plug.Conn.put_resp_header(conn, "x-poll-interval", poll), else: conn

      if Plug.Conn.get_req_header(conn, "if-none-match") == [etag] do
        Agent.update(api, &update_in(&1.served[304], fn n -> n + 1 end))
        conn |> Plug.Conn.put_resp_header("etag", etag) |> Plug.Conn.send_resp(304, "")
      else
        Agent.update(api, &update_in(&1.served[200], fn n -> n + 1 end))
        conn |> Plug.Conn.put_resp_header("etag", etag) |> Req.Test.json(items)
      end
    end)

    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    %{api: api}
  end

  defp config,
    do:
      Config.new([
        [base_url: "http://api.test", max_retries: 0, req_options: [plug: {Req.Test, __MODULE__}]]
      ])

  defp set(api, issues), do: Agent.update(api, &%{&1 | issues: issues})
  defp served(api), do: Agent.get(api, & &1.served)

  defp issue(id, title, state \\ "open"),
    do: %{"id" => id, "title" => title, "state" => state, "updated_at" => "t0"}

  defp next_event(watcher, timeout \\ 500) do
    receive do
      {:infusion_watch, ^watcher, event} -> event
    after
      timeout -> :timeout
    end
  end

  test "created, updated and deleted, with what changed", %{api: api} do
    set(api, [issue(1, "Crash"), issue(2, "Typo")])
    {:ok, w} = Watch.start_link(config(), @op, [], %{}, every: 20)

    # only changes from now on
    assert next_event(w, 80) == :timeout

    set(api, [issue(1, "Crash on boot", "closed"), issue(2, "Typo"), issue(3, "Docs")])

    events = [next_event(w), next_event(w)] |> Enum.sort_by(& &1.id)

    assert [
             %Event{
               type: :updated,
               id: 1,
               item: %Issue{title: "Crash on boot"},
               previous: %Issue{title: "Crash"},
               changes: %{title: {"Crash", "Crash on boot"}, state: {"open", "closed"}},
               operation: "GET /issues"
             },
             %Event{type: :created, id: 3, item: %Issue{title: "Docs"}}
           ] = events

    set(api, [issue(1, "Crash on boot", "closed"), issue(3, "Docs")])
    assert %Event{type: :deleted, id: 2, item: %Issue{title: "Typo"}} = next_event(w)
    Watch.stop(w)
  end

  test "unchanged pages cost a 304 and nothing else", %{api: api} do
    set(api, [issue(1, "a")])
    {:ok, w} = Watch.start_link(config(), @op, [], %{per_page: 10}, every: 10)
    ref = :telemetry_test.attach_event_handlers(self(), [[:infusion, :watch, :poll]])

    for _ <- 1..5 do
      assert_receive {[:infusion, :watch, :poll], ^ref, %{pages: 1, not_modified: 1, created: 0},
                      _},
                     500
    end

    assert %{200 => 1, 304 => n} = served(api)
    assert n >= 5
    Watch.stop(w)
  end

  test "every page of the list, conditionally; a partial view never reports deletes", %{api: api} do
    set(api, for(i <- 1..5, do: issue(i, "##{i}")))
    {:ok, w} = Watch.start_link(config(), @op, [], %{per_page: 2}, every: 20)
    # 3 pages read
    assert %{200 => 3} = served(api)

    set(api, for(i <- 2..5, do: issue(i, "##{i}")))
    assert %Event{type: :deleted, id: 1} = next_event(w)
    Watch.stop(w)

    # Only the first page of 2: issue 1 scrolling out isn't a delete; an
    # unseen item is :created when it was created after the watcher started,
    # :entered when it is an old one that moved into view.
    set(api, for(i <- 1..5, do: issue(i, "##{i}")))
    {:ok, w} = Watch.start_link(config(), @op, [], %{per_page: 2}, every: 20, pages: 1)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    set(api, [Map.put(issue(9, "new"), "created_at", now) | for(i <- 2..5, do: issue(i, "##{i}"))])

    assert %Event{type: :created, id: 9} = next_event(w)
    assert next_event(w, 100) == :timeout

    old = Map.put(issue(4, "#4 bumped"), "created_at", "2019-01-01T00:00:00Z")
    set(api, [old, Map.put(issue(9, "new"), "created_at", now), issue(5, "#5")])
    assert %Event{type: :entered, id: 4} = next_event(w)
    Watch.stop(w)
  end

  test "creation times as Twilio and Stripe write them", %{api: api} do
    set(api, [issue(1, "a"), issue(2, "b")])
    {:ok, w} = Watch.start_link(config(), @op, [], %{per_page: 2}, every: 20, pages: 1)

    now = DateTime.utc_now()
    twilio_now = Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S +0000")

    set(api, [
      Map.put(issue(3, "twilio new"), "date_created", twilio_now),
      Map.put(issue(4, "stripe old"), "created", 1_500_000_000)
    ])

    events = [next_event(w), next_event(w)] |> Enum.sort_by(& &1.id)
    assert [%Event{type: :created, id: 3}, %Event{type: :entered, id: 4}] = events

    set(api, [
      Map.put(issue(5, "stripe new"), "created", DateTime.to_unix(now)),
      Map.put(issue(6, "twilio old"), "date_created", "Mon, 05 Jan 2015 10:00:00 +0000")
    ])

    events = [next_event(w), next_event(w)] |> Enum.sort_by(& &1.id)
    assert [%Event{type: :created, id: 5}, %Event{type: :entered, id: 6}] = events
    Watch.stop(w)
  end

  test "initial items, ignored fields, a function as the target", %{api: api} do
    set(api, [issue(1, "a"), issue(2, "b")])
    test = self()

    {:ok, w} =
      Watch.start_link(config(), @op, [], %{},
        every: 20,
        initial: true,
        ignore: [:updated_at],
        to: fn event -> send(test, {:got, event}) end
      )

    assert_receive {:got, %Event{type: :created, id: 1}}
    assert_receive {:got, %Event{type: :created, id: 2}}

    set(api, [%{issue(1, "a") | "updated_at" => "t1"}, issue(2, "b")])
    refute_receive {:got, _}, 100

    set(api, [
      Map.merge(issue(1, "a"), %{"updated_at" => "t2", "labels" => ["bug"]}),
      issue(2, "b")
    ])

    assert_receive {:got, %Event{type: :updated, changes: changes}}
    # fields the SDK doesn't know are compared too, by their JSON name
    assert changes == %{"labels" => {nil, ["bug"]}}
    Watch.stop(w)
  end

  test "a failing first poll is an error now; a later one is an :error event", %{api: api} do
    Req.Test.stub(
      __MODULE__,
      &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"}))
    )

    assert {:error, %Infusion.Runtime.Error{type: :not_found}} =
             Watch.start_link(config(), @op, [], %{})

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, [issue(1, "a")]))
    {:ok, w} = Watch.start_link(config(), @op, [], %{per_page: 10}, every: 20)
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))
    assert %Event{type: :error, error: %{type: :internal_server}} = next_event(w)

    # and it keeps watching
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, [issue(1, "a"), issue(2, "b")]))

    assert %Event{type: :created, id: 2} =
             Stream.reject(Watch.stream(w), &(&1.type == :error)) |> Enum.at(0)

    Watch.stop(w)
    _ = api
  end

  test "broadcast with Phoenix.PubSub, for LiveViews", %{api: api} do
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    Phoenix.PubSub.subscribe(__MODULE__.PubSub, "issues")
    set(api, [issue(1, "a")])

    {:ok, w} =
      Watch.start_link(config(), @op, [], %{},
        every: 20,
        to: {:pubsub, __MODULE__.PubSub, "issues"}
      )

    set(api, [issue(1, "a", "closed")])

    assert_receive {:infusion_watch, ^w,
                    %Event{type: :updated, changes: %{state: {"open", "closed"}}}},
                   500

    Watch.stop(w)
  end

  test "the server's X-Poll-Interval is the minimum", %{api: api} do
    Agent.update(api, &%{&1 | poll: "60"})
    set(api, [issue(1, "a")])
    {:ok, w} = Watch.start_link(config(), @op, [], %{}, every: 10)
    set(api, [issue(1, "b")])
    assert next_event(w, 150) == :timeout
    Watch.stop(w)
  end
end
