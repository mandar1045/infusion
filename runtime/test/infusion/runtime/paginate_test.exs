defmodule Infusion.Runtime.PaginateTest do
  use ExUnit.Case, async: true

  alias Infusion.Runtime.{Config, Error, Paginate}

  defmodule Item do
    defstruct [:id, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:id, "id", :string}]
  end

  setup do
    Req.Test.verify_on_exit!()
    test = self()

    config =
      Config.new([
        [
          base_url: "https://api.test/v1",
          req_options: [plug: {Req.Test, __MODULE__}],
          sleep: fn ms -> send(test, {:slept, ms}) end
        ]
      ])

    %{config: config}
  end

  defp op(paginate, params \\ []) do
    %{
      id: "list",
      method: :get,
      path: "/items",
      path_params: [],
      params: params,
      response: nil,
      paginate: Map.merge(%{items: ["data"], item: {:ref, Item}}, paginate)
    }
  end

  defp items(ids), do: Enum.map(ids, &%{"id" => &1})
  defp ids(stream), do: Enum.map(stream, & &1.id)

  # Answers each request with the next page, and records the query strings.
  defp pages(pages) do
    test = self()

    for page <- pages do
      Req.Test.expect(__MODULE__, fn conn ->
        send(test, {:query, conn.request_path, conn.query_string})

        {headers, body} =
          case page do
            {headers, body} -> {headers, body}
            body -> {[], body}
          end

        conn
        |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end))
        |> Req.Test.json(body)
      end)
    end
  end

  defp queries do
    Stream.repeatedly(fn ->
      receive do
        {:query, path, query} -> {path, query}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  test "cursor_after (OpenAI, Stripe): after the last id while has_more", %{config: config} do
    pages([
      %{"data" => items(~w(a b)), "has_more" => true},
      %{"data" => items(~w(c)), "has_more" => false}
    ])

    op = op(%{style: :cursor_after, param: "after"}, [{:limit, "limit", :query}])
    assert {:ok, stream} = Paginate.stream(config, op, [], limit: 2)
    assert ids(stream) == ~w(a b c)
    assert queries() == [{"/v1/items", "limit=2"}, {"/v1/items", "limit=2&after=b"}]
  end

  test "cursor_after prefers last_id, and pages backwards from before", %{config: config} do
    pages([
      %{"data" => items(~w(a b)), "has_more" => true, "last_id" => "b-cursor"},
      %{"data" => items(~w(c)), "has_more" => false}
    ])

    {:ok, stream} = Paginate.stream(config, op(%{style: :cursor_after, param: "after"}), [], [])
    assert ids(stream) == ~w(a b c)
    assert [_, {_, "after=b-cursor"}] = queries()

    pages([
      %{"data" => items(~w(y z)), "has_more" => true},
      %{"data" => items(~w(x)), "has_more" => false}
    ])

    op = op(%{style: :cursor_after, param: "starting_after"})
    {:ok, stream} = Paginate.stream(config, op, [], ending_before: "zz")
    assert ids(stream) == ~w(y z x)
    assert [_, {_, "ending_before=y"}] = queries()
  end

  test "stopping early fetches no more pages", %{config: config} do
    pages([%{"data" => items(~w(a b)), "has_more" => true}])
    {:ok, stream} = Paginate.stream(config, op(%{style: :cursor_after, param: "after"}), [], [])
    assert ids(Enum.take(stream, 2)) == ~w(a b)
  end

  test "cursor (Cloudflare, Stripe search): send back the cursor", %{config: config} do
    pages([
      %{"result" => items(~w(a)), "result_info" => %{"cursor" => "c2"}},
      %{"result" => items(~w(b)), "result_info" => %{"cursor" => ""}}
    ])

    op =
      op(%{style: :cursor, param: "cursor", from: ["result_info", "cursor"], items: ["result"]})

    {:ok, stream} = Paginate.stream(config, op, [], [])
    assert ids(stream) == ~w(a b)
    assert queries() == [{"/v1/items", ""}, {"/v1/items", "cursor=c2"}]
  end

  test "next_url (Twilio): follow the relative URL in the response", %{config: config} do
    pages([
      %{"calls" => items(~w(a)), "next_page_uri" => "/v1/Calls.json?Page=1&PageToken=PA"},
      %{"calls" => items(~w(b)), "next_page_uri" => nil}
    ])

    op = %{
      op(%{style: :next_url, from: ["next_page_uri"], items: ["calls"]}, [
        {:page_size, "PageSize", :query}
      ])
      | path: "/Calls.json"
    }

    {:ok, stream} = Paginate.stream(config, op, [], page_size: 1)
    assert ids(stream) == ~w(a b)

    assert queries() == [
             {"/v1/Calls.json", "PageSize=1"},
             {"/v1/Calls.json", "Page=1&PageToken=PA"}
           ]
  end

  test "page with a Link header (GitHub): follow it until there's no next", %{config: config} do
    pages([
      {[
         {"link",
          ~s(<https://api.test/v1/items?per_page=2&page=2>; rel="next", <https://api.test/v1/items?per_page=2&page=3>; rel="last")}
       ], items(~w(a b))},
      {[{"link", ~s(<https://api.test/v1/items?per_page=2&page=3>; rel="next")}], items(~w(c d))},
      {[{"link", ~s(<https://api.test/v1/items?per_page=2&page=1>; rel="first")}], items(~w(e))}
    ])

    op =
      op(%{style: :page, param: "page", per_page: "per_page", items: []}, [
        {:per_page, "per_page", :query}
      ])

    {:ok, stream} = Paginate.stream(config, op, [], per_page: 2)
    assert ids(stream) == ~w(a b c d e)

    assert Enum.map(queries(), &elem(&1, 1)) == [
             "per_page=2",
             "per_page=2&page=2",
             "per_page=2&page=3"
           ]
  end

  test "page without a Link header: numbers, until total_pages or a short page", %{config: config} do
    pages([
      %{"result" => items(~w(a)), "result_info" => %{"total_pages" => 2}},
      %{"result" => items(~w(b)), "result_info" => %{"total_pages" => 2}}
    ])

    op =
      op(%{
        style: :page,
        param: "page",
        total_pages: ["result_info", "total_pages"],
        items: ["result"]
      })

    {:ok, stream} = Paginate.stream(config, op, [], [])
    assert ids(stream) == ~w(a b)
    assert Enum.map(queries(), &elem(&1, 1)) == ["", "page=2"]

    pages([items(~w(a b)), items(~w(c))])
    op = op(%{style: :page, param: "page", per_page: "per_page", items: []})
    {:ok, stream} = Paginate.stream(config, op, [], per_page: 2, page: 1)
    assert ids(stream) == ~w(a b c)
    assert Enum.map(queries(), &elem(&1, 1)) == ["per_page=2&page=1", "per_page=2&page=2"]
  end

  test "offset", %{config: config} do
    pages([%{"data" => items(~w(a b))}, %{"data" => items(~w(c))}])

    {:ok, stream} =
      Paginate.stream(config, op(%{style: :offset, param: "offset", limit: "limit"}), [],
        limit: 2
      )

    assert ids(stream) == ~w(a b c)
    assert Enum.map(queries(), &elem(&1, 1)) == ["limit=2", "limit=2&offset=2"]
  end

  test "an empty page ends the stream, whatever the API says", %{config: config} do
    pages([%{"data" => [], "has_more" => true}])
    {:ok, stream} = Paginate.stream(config, op(%{style: :cursor_after, param: "after"}), [], [])
    assert Enum.to_list(stream) == []
  end

  test "the first page's error is returned; a later page's is raised", %{config: config} do
    Req.Test.expect(
      __MODULE__,
      &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"}))
    )

    assert {:error, %Error{type: :not_found}} =
             Paginate.stream(config, op(%{style: :cursor_after, param: "after"}), [], [])

    pages([%{"data" => items(~w(a)), "has_more" => true}])

    Req.Test.expect(
      __MODULE__,
      &(&1 |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Nope"}))
    )

    {:ok, stream} = Paginate.stream(config, op(%{style: :cursor_after, param: "after"}), [], [])
    assert_raise Error, "403: Nope", fn -> Enum.to_list(stream) end
  end
end
