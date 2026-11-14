defmodule Infusion.Runtime.Paginate do
  @moduledoc """
  Turns a list operation into a lazy stream of every item, fetching pages
  as they are needed.

      {:ok, repos} = GitHub.Repos.list_for_org_all("elixir-lang", per_page: 100)
      repos |> Stream.map(& &1.name) |> Enum.take(250)   # fetches 3 pages

  The operation's `paginate` map says how the API pages:

    * `style: :cursor_after, param: "after"`: while `has_more`, ask for the
      items after the last one's `id` (OpenAI, Stripe). Paging backwards
      (`before`, `ending_before`) works the same way from the first item.
    * `style: :cursor, param: "cursor", from: ["result_info", "cursor"]`:
      send back the cursor the response holds (Cloudflare, Stripe search).
    * `style: :next_url, from: ["next_page_uri"]`: follow the URL the
      response holds (Twilio).
    * `style: :page, param: "page"`: follow the `Link` header when there is
      one (GitHub), else ask for the next page number until a page comes back
      empty, short, or past `total_pages`.
    * `style: :offset, param: "offset", limit: "limit"`
    * `style: :link_header`: follow `rel="next"` in the `Link` header.

  plus `items` (where the list is in the response, `[]` for the response
  itself) and `item` (the item type).

  The first page is fetched right away, so its errors come back as
  `{:error, error}`. A later page that fails raises `Infusion.Runtime.Error`
  (after the usual retries). Stopping early fetches no more pages.
  """

  alias Infusion.Runtime.{Config, Error, Request, Schema}

  @doc "Runs `operation` and returns `{:ok, stream}` of all its items."
  @spec stream(Config.t(), map, [term], map | keyword, keyword) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Config{} = config, operation, path_args, params, opts \\ []) do
    pagination = Map.fetch!(operation, :paginate)
    params = Enum.to_list(params)
    first = %{operation: operation, path_args: path_args, params: params}

    with {:ok, page} <- fetch(config, first, opts) do
      stream =
        Stream.resource(
          fn -> {:page, page, first} end,
          fn
            :done ->
              {:halt, :done}

            {:page, response, request} ->
              emit(response, request, pagination)

            {:fetch, request} ->
              case fetch(config, request, opts) do
                {:ok, response} -> emit(response, request, pagination)
                {:error, error} -> raise error
              end
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    end
  end

  # One page, undecoded: the paging fields are read from the JSON.
  defp fetch(config, request, opts) do
    operation = %{request.operation | response: nil} |> Map.delete(:paginate)

    Request.run(
      config,
      operation,
      request.path_args,
      request.params,
      Keyword.put(opts, :raw, true)
    )
  end

  defp emit(%Req.Response{body: json} = response, request, pagination) do
    raw = items(json, pagination.items)
    decoded = Enum.map(raw, &Schema.decode(&1, pagination[:item]))
    next = if raw == [], do: :done, else: next(pagination, response, raw, request)
    {decoded, next}
  end

  defp items(json, []) when is_list(json), do: json

  defp items(json, path) when is_map(json) do
    case get_in(json, path) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp items(_json, _path), do: []

  ## The next request, per style

  defp next(%{style: :cursor_after, param: after_param}, %{body: json}, raw, request) do
    before_param = if after_param == "after", do: "before", else: "ending_before"

    {param, item} =
      if get(request, before_param) != nil,
        do: {before_param, List.first(raw)},
        else: {after_param, List.last(raw)}

    cursor = (param == after_param && field(json, ["last_id"])) || id(item)

    if field(json, ["has_more"]) == true and cursor != nil,
      do: {:fetch, put(request, param, cursor)},
      else: :done
  end

  defp next(%{style: :cursor, param: param, from: from}, %{body: json}, _raw, request) do
    case field(json, from) do
      cursor when cursor in [nil, ""] ->
        :done

      cursor ->
        if cursor == get(request, param), do: :done, else: {:fetch, put(request, param, cursor)}
    end
  end

  defp next(%{style: :next_url, from: from}, %{body: json} = response, _raw, request) do
    case field(json, from) do
      url when is_binary(url) and url != "" -> follow(request, response, url)
      _ -> :done
    end
  end

  defp next(%{style: :page} = p, %{body: json} = response, raw, request) do
    with :none <- link_next(response, request) do
      page = to_integer(get(request, p.param)) || 1
      total = p[:total_pages] && to_integer(field(json, p.total_pages))
      per_page = p[:per_page] && to_integer(get(request, p.per_page))

      cond do
        total != nil and page >= total -> :done
        per_page != nil and length(raw) < per_page -> :done
        true -> {:fetch, put(request, p.param, page + 1)}
      end
    end
  end

  defp next(%{style: :offset} = p, _response, raw, request) do
    limit = to_integer(get(request, p.limit))

    if limit != nil and length(raw) < limit,
      do: :done,
      else:
        {:fetch, put(request, p.param, (to_integer(get(request, p.param)) || 0) + length(raw))}
  end

  defp next(%{style: :link_header}, response, _raw, request) do
    with :none <- link_next(response, request), do: :done
  end

  defp next(_pagination, _response, _raw, _request), do: :done

  # rel="next" in a Link header: <https://api.github.com/...?page=2>; rel="next".
  # :none when there's no Link header at all; an API that sends one and
  # leaves out "next" is on its last page.
  defp link_next(response, request) do
    case Req.Response.get_header(response, "link") do
      [] ->
        :none

      headers ->
        headers
        |> Enum.flat_map(&Regex.scan(~r/<([^>]*)>\s*;\s*rel="?([^";,]*)"?/, &1))
        |> Enum.find_value(fn [_, url, rels] -> if "next" in String.split(rels), do: url end)
        |> case do
          nil -> :done
          url -> follow(request, response, url)
        end
    end
  end

  # A URL to follow already has the query, so only header parameters stay.
  # A relative URL (Twilio's next_page_uri) is relative to the last request.
  defp follow(request, response, url) do
    current = to_string(response_url(response))
    absolute = if current == "", do: url, else: current |> URI.merge(url) |> to_string()

    if absolute == current do
      :done
    else
      headers =
        Enum.filter(request.params, fn {key, _} -> location(request, key) == :header end)

      operation = Map.merge(request.operation, %{url: absolute})
      {:fetch, %{request | operation: operation, path_args: [], params: headers}}
    end
  end

  defp response_url(%Req.Response{} = response) do
    case Req.Response.get_private(response, :infusion_url) do
      nil -> ""
      url -> url
    end
  end

  ## Parameters, by their name on the wire

  defp get(request, name) do
    Enum.find_value(request.params, fn {key, value} ->
      if wire(request, key) == name, do: value
    end)
  end

  defp put(request, name, value) do
    params = Enum.reject(request.params, fn {key, _} -> wire(request, key) == name end)
    %{request | params: params ++ [{name, value}]}
  end

  defp wire(request, key) do
    Enum.find_value(request.operation[:params] || [], to_string(key), fn {k, name, _} ->
      if k == key or name == key, do: name
    end)
  end

  defp location(request, key) do
    Enum.find_value(request.operation[:params] || [], fn {k, name, where} ->
      if k == key or name == key, do: where
    end)
  end

  defp field(json, path) when is_map(json), do: get_in(json, path)
  defp field(_json, _path), do: nil

  defp id(%{"id" => id}), do: id
  defp id(_item), do: nil

  defp to_integer(nil), do: nil
  defp to_integer(n) when is_integer(n), do: n

  defp to_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_integer(_), do: nil
end
