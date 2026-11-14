defmodule Infusion.Gen.Pagination do
  @moduledoc """
  Works out how a list operation pages, from its parameters and response.

  Specs don't say how an API paginates, but the shapes are recognisable:

  | style | seen in | recognised by |
  |---|---|---|
  | `:cursor_after` | OpenAI, Stripe | an `after` / `starting_after` parameter and a `has_more` field |
  | `:cursor` | Cloudflare, Slack | a `cursor` parameter and a `cursor` / `next_cursor` field in the response |
  | `:next_url` | Twilio | a `next_page_uri` / `next_page_url` field |
  | `:page` | GitHub, Cloudflare | a `page` parameter; GitHub's `Link` header is followed when sent |
  | `:offset` | Cloudflare | `offset` and `limit` parameters |
  | `:link_header` | GitHub | any other paging parameter (`per_page`, `after`): follows `rel="next"` in the `Link` header, if the API sends one |

  The result is data for the runtime: where the items are (`items`, a path
  into the response), how each item decodes (`item`, a schema), and what the
  style needs (parameter names, paths to fields).
  """

  alias Infusion.IR
  alias Infusion.IR.{Operation, Schema}

  @doc "The pagination of `op`, or nil if it doesn't page."
  @spec detect(%Operation{}, %IR{}) :: map | nil
  def detect(%Operation{method: :get} = op, %IR{} = ir) do
    with %Schema{} = response <- success_schema(op),
         {items, item} <- items(resolve(response, ir), ir),
         style when style != nil <- style(op, resolve(response, ir), ir) do
      Map.merge(style, %{items: items, item: item})
    else
      _ -> nil
    end
  end

  def detect(_op, _ir), do: nil

  defp success_schema(%Operation{responses: responses}) do
    responses
    |> Enum.filter(fn {status, _} -> is_binary(status) and String.starts_with?(status, "2") end)
    |> Enum.sort()
    |> Enum.find_value(fn {_, r} -> r.schema end)
  end

  # Where the items are: the response itself when it is a list (GitHub),
  # else its list field (data, result, items, or the only list there is).
  defp items(%Schema{kind: :array, items: item}, _ir), do: {[], item}

  defp items(%Schema{kind: :object, fields: fields}, ir) do
    lists =
      for f <- fields,
          %Schema{kind: :array, items: item} <- [resolve(f.schema, ir)],
          do: {f.name, item}

    preferred = Enum.find(lists, fn {name, _} -> name in ~w(data result results items) end)

    case {preferred, lists} do
      {{name, item}, _} -> {[name], item}
      {nil, [{name, item}]} -> {[name], item}
      _ -> nil
    end
  end

  # A union of lists (GitHub's starred repositories, with or without the
  # star's timestamp): the items are a union of the item types.
  defp items(%Schema{kind: :union, variants: variants}, ir) do
    item_types =
      Enum.map(variants, fn v ->
        case resolve(v, ir) do
          %Schema{kind: :array, items: item} -> item
          _ -> nil
        end
      end)

    if item_types != [] and Enum.all?(item_types),
      do: {[], %Schema{kind: :union, variants: item_types}},
      else: nil
  end

  defp items(_schema, _ir), do: nil

  defp style(op, response, ir) do
    query = MapSet.new(op.query_params, & &1.name)
    fields = field_names(response, ir)
    has? = &MapSet.member?(query, &1)

    # A cursor parameter (a string, even when it's called `page`, as in
    # Stripe's search and OpenAI's usage endpoints) and the field that holds
    # the next value.
    cursor_param =
      Enum.find(op.query_params, fn p ->
        p.name in ~w(cursor page page_token pageToken) and string?(p.schema, ir)
      end)

    cursor_field =
      Enum.find(
        [
          ["cursor"],
          ["next_cursor"],
          ["next_page"],
          ["next_page_token"],
          ["nextPageToken"],
          ["next"],
          ["result_info", "cursor"],
          ["response_metadata", "next_cursor"]
        ],
        &(&1 in fields)
      )

    next_url =
      Enum.find(
        [["next_page_uri"], ["next_page_url"], ["meta", "next_page_url"], ["next"]],
        &(&1 in fields)
      )

    cond do
      (has?.("after") or has?.("starting_after")) and ["has_more"] in fields ->
        %{style: :cursor_after, param: if(has?.("after"), do: "after", else: "starting_after")}

      cursor_param && cursor_field ->
        %{style: :cursor, param: cursor_param.name, from: cursor_field}

      next_url && next_url != ["next"] ->
        %{style: :next_url, from: next_url}

      has?.("page") ->
        %{
          style: :page,
          param: "page",
          per_page: Enum.find(~w(per_page page_size limit), has?),
          total_pages:
            Enum.find([["result_info", "total_pages"], ["total_pages"]], &(&1 in fields))
        }

      has?.("offset") and has?.("limit") ->
        %{style: :offset, param: "offset", limit: "limit"}

      Enum.any?(~w(per_page page_size limit after before), has?) ->
        %{style: :link_header}

      true ->
        nil
    end
  end

  defp string?(schema, ir),
    do: match?(%Schema{kind: :scalar, type: "string"}, resolve(schema, ir))

  # Field paths of the response, two levels deep: [["has_more"], ["result_info", "cursor"]].
  defp field_names(%Schema{kind: :object, fields: fields}, ir) do
    Enum.flat_map(fields, fn f ->
      nested =
        case resolve(f.schema, ir) do
          %Schema{kind: :object, fields: inner} -> Enum.map(inner, &[f.name, &1.name])
          _ -> []
        end

      [[f.name] | nested]
    end)
  end

  defp field_names(_schema, _ir), do: []

  defp resolve(schema, ir, depth \\ 0)

  defp resolve(%Schema{kind: :ref, ref: ref}, ir, depth) when depth < 10 do
    case ir.schemas[ref] do
      nil -> %Schema{kind: :any}
      schema -> resolve(schema, ir, depth + 1)
    end
  end

  defp resolve(schema, _ir, _depth), do: schema
end
