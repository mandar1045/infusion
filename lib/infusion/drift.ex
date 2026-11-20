defmodule Infusion.Drift do
  @moduledoc """
  Turns what an SDK saw the real API return (a report written by
  `Infusion.Runtime.Drift.export/1`) into fixes for the spec.

  Every finding names a generated module and a field. This traces it back
  through the generator (module renames, inline objects lifted into their
  own modules, `allOf` merges, `$ref`s) to the exact place in the vendor's
  spec that is wrong, and proposes an `Infusion.Patch` for it:

  | Finding | Patch |
  |---|---|
  | `undocumented_field` | `merge` the property into the object, with the types seen |
  | `unexpected_null` | `merge` `nullable: true` into the property |
  | `missing_required` | `unrequire` it where it is listed as required |
  | `unknown_enum` | `add_enum` the value |
  | `wrong_type` (between scalars) | `merge` a type list with both types |
  | `unknown_variant`, `unmatched_union`, other `wrong_type` | none: reported only |

  `mix infusion.drift` is the command line for it.
  """

  alias Infusion.Patch

  @added "Not in the vendor's spec: added by `mix infusion.drift` from real responses."

  @doc """
  Analyzes `findings` (the `"findings"` of an export, string keys) for the
  SDK built by `Infusion.build/2`. Returns one entry per finding, in order:

      %{finding: map, pointer: "/components/schemas/..." | nil,
        patches: [patch], note: String.t() | nil}

  plus `fixed?: true` when the spec (with its patches) already agrees
  with the API.
  """
  @spec analyze([map], map) :: [map]
  def analyze(findings, %{spec: spec, ir: ir, modules: modules}) do
    keys = Map.new(modules, fn {key, module} -> {module, key} end)
    ctx = %{spec: spec, ir: ir, keys: keys, origins: %{}}

    {entries, _ctx} =
      findings
      |> group_undocumented()
      |> Enum.map_reduce(ctx, fn finding, ctx ->
        {origin, ctx} = origin(finding["schema"], ctx)
        {entry(finding, origin, ctx), ctx}
      end)

    entries
  end

  # The same undocumented field seen with several types (a string, and
  # sometimes null) is one property.
  defp group_undocumented(findings) do
    {undocumented, rest} = Enum.split_with(findings, &(&1["kind"] == "undocumented_field"))

    grouped =
      undocumented
      |> Enum.group_by(&{&1["schema"], &1["path"]})
      |> Enum.map(fn {_, [first | _] = group} ->
        %{
          first
          | "got" =>
              group |> Enum.map(& &1["got"]) |> Enum.uniq() |> Enum.sort() |> Enum.join("|"),
            "count" => group |> Enum.map(&(&1["count"] || 0)) |> Enum.sum(),
            "operations" =>
              group |> Enum.flat_map(&(&1["operations"] || [])) |> Enum.uniq() |> Enum.sort()
        }
      end)

    Enum.sort_by(grouped ++ rest, &{-(&1["count"] || 0), &1["schema"] || "", &1["path"]})
  end

  defp entry(finding, nil, _ctx) do
    %{finding: finding, pointer: nil, patches: [], note: note(finding, "not traced to the spec")}
  end

  defp entry(%{"kind" => kind, "path" => path} = finding, object, ctx) do
    {field, rest} = split_path(path, object.key, ctx.ir)

    case kind do
      "undocumented_field" ->
        at = object.segments ++ ["properties", field]

        patch = %{
          "op" => "merge",
          "path" => Patch.pointer(at),
          "value" => property(finding["got"])
        }

        result(finding, at, [patch])

      "unexpected_null" ->
        with_property(finding, object, field, rest, ctx, fn at ->
          [%{"op" => "merge", "path" => Patch.pointer(at), "value" => %{"nullable" => true}}]
        end)

      "missing_required" ->
        case required_at(ctx.spec, object.segments, field, MapSet.new()) do
          [] ->
            %{
              finding: finding,
              pointer: Patch.pointer(object.segments),
              patches: [],
              note: "not listed as required in the spec",
              fixed?: true
            }

          places ->
            patches =
              for p <- places,
                  do: %{"op" => "unrequire", "path" => Patch.pointer(p), "value" => [field]}

            result(finding, hd(places), patches)
        end

      "unknown_enum" ->
        with_property(finding, object, field, rest, ctx, fn at ->
          {target, node} = deref(ctx.spec, at)

          if is_list(node["enum"]),
            do: [
              %{
                "op" => "add_enum",
                "path" => Patch.pointer(target),
                "value" => [enum_value(node["enum"], finding["got"])]
              }
            ],
            else: []
        end)

      "wrong_type" ->
        scalars = ~w(string integer number boolean)

        with_property(finding, object, field, rest, ctx, fn at ->
          if finding["expected"] in scalars and finding["got"] in scalars do
            [
              %{
                "op" => "merge",
                "path" => Patch.pointer(at),
                "value" => %{"type" => [finding["expected"], finding["got"]]}
              }
            ]
          else
            []
          end
        end)

      _ ->
        with_property(finding, object, field, rest, ctx, fn _ -> [] end)
    end
  end

  defp with_property(finding, object, field, rest, ctx, fun) do
    case property_at(ctx.spec, object.segments, field, MapSet.new()) do
      nil ->
        %{
          finding: finding,
          pointer: Patch.pointer(object.segments),
          patches: [],
          note: note(finding, "property not found in the spec")
        }

      at ->
        at = descend(ctx.spec, at, rest)

        case at do
          nil -> %{finding: finding, pointer: nil, patches: [], note: "not traced to the spec"}
          at -> result(finding, at, fun.(at))
        end
    end
  end

  defp result(finding, at, patches) do
    note = if patches == [], do: note(finding, nil), else: nil

    %{
      finding: finding,
      pointer: Patch.pointer(at),
      patches: Enum.map(patches, &seen(&1, finding)),
      note: note
    }
  end

  defp seen(patch, finding) do
    Map.put(
      patch,
      "reason",
      "#{finding["kind"]}, seen #{finding["count"]}x in #{Enum.join(finding["operations"] || [], ", ")}"
    )
  end

  defp note(%{"kind" => "unknown_variant"}, _), do: "a new variant: report it to the API's owners"

  defp note(%{"kind" => "unmatched_union"}, _),
    do: "fits no variant: report it to the API's owners"

  defp note(%{"kind" => "wrong_type"}, _), do: "report it to the API's owners"
  defp note(_finding, default), do: default

  defp property(got) do
    types = String.split(got, "|")
    {nulls, types} = Enum.split_with(types, &(&1 == "null"))

    base =
      case types do
        [] -> %{}
        [type] -> %{"type" => type}
        types -> %{"type" => types}
      end

    base
    |> Map.put("description", @added)
    |> then(&if nulls != [], do: Map.put(&1, "nullable", true), else: &1)
  end

  # The runtime reports enum values as text; integer enums get integers back.
  defp enum_value([first | _], value) when is_integer(first) do
    case Integer.parse(value) do
      {i, ""} -> i
      _ -> value
    end
  end

  defp enum_value(_values, value), do: value

  ## Where a generated module comes from

  # %{key: schema key, segments: pointer to the object schema} | nil
  defp origin(nil, ctx), do: {nil, ctx}

  defp origin(module, ctx) do
    case Map.fetch(ctx.origins, module) do
      {:ok, origin} ->
        {origin, ctx}

      :error ->
        origin =
          with {:ok, key} <- Map.fetch(ctx.keys, module),
               segments when segments != nil <- key_segments(key, ctx) do
            {segments, _node} = deref(ctx.spec, segments)
            %{key: key, segments: segments}
          else
            _ -> nil
          end

        {origin, %{ctx | origins: Map.put(ctx.origins, module, origin)}}
    end
  end

  # Schema keys (see Infusion.Gen.Schemas): component names; "#op:GET
  # /path:200" (and "...~" for the events) for inline responses; "Parent.field"
  # plus "[]" (items), "{}" (map values) and "|n" (union variants) for objects
  # written inline in another.
  defp key_segments("#op:" <> rest, ctx) do
    stream? = String.ends_with?(rest, "~")
    rest = String.trim_trailing(rest, "~")

    with [method, path_status] <- String.split(rest, " ", parts: 2),
         [path, status] <- split_last(path_status, ":"),
         %{} = op <-
           Enum.find(
             ctx.ir.operations,
             &(to_string(&1.method) == String.downcase(method) and &1.path == path)
           ),
         %{} = response <- op.responses[status] do
      content_type = if stream?, do: "text/event-stream", else: response.content_type
      responses = ["paths", path, String.downcase(method), "responses", status]

      # A response written as a $ref to components/responses is fixed there.
      {responses, _} = deref(ctx.spec, responses)
      segments = responses ++ ["content", content_type, "schema"]
      if get(ctx.spec, segments) != nil, do: segments
    else
      _ -> nil
    end
  end

  defp key_segments(key, ctx) do
    components = ["components", "schemas", key]

    cond do
      get(ctx.spec, components) != nil and not String.starts_with?(key, "#") ->
        components

      true ->
        inline_segments(key, ctx)
    end
  end

  # "Parent.field[]": the longest key that is a prefix, followed by one of
  # its fields.
  defp inline_segments(key, ctx) do
    container_segments(key, ctx) || field_segments(key, ctx)
  end

  # "CoinsMarkets[]": the items of a named list (or map values, or variants).
  defp container_segments(key, ctx) do
    case Regex.run(~r/^(.*?)((?:\[\]|\{\}|\|\d+)+)$/, key) do
      [_, parent, suffix] when parent != "" ->
        if get(ctx.spec, ["components", "schemas", parent]) != nil,
          do: descend(ctx.spec, ["components", "schemas", parent], suffix)

      _ ->
        nil
    end
  end

  defp field_segments(key, ctx) do
    ctx.ir.schemas
    |> Map.keys()
    |> Enum.filter(&(String.starts_with?(key, &1 <> ".") and &1 != key))
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.find_value(fn parent ->
      rest = String.replace_prefix(key, parent <> ".", "")

      with {field, suffix} <- split_field(rest, field_names(ctx.ir, parent)),
           parent_segments when parent_segments != nil <- key_segments(parent, ctx),
           {parent_segments, _} = deref(ctx.spec, parent_segments),
           at when at != nil <- property_at(ctx.spec, parent_segments, field, MapSet.new()) do
        descend(ctx.spec, at, suffix)
      else
        _ -> nil
      end
    end)
  end

  defp field_names(ir, key) do
    case ir.schemas[key] do
      %{fields: fields} -> Enum.map(fields, & &1.name)
      _ -> []
    end
  end

  # "labels[].color" in schema `key`: the field ("labels") and what follows.
  defp split_path(path, key, ir) do
    case split_field(path, field_names(ir, key)) do
      nil -> {path, ""}
      found -> found
    end
  end

  defp split_field(text, names) do
    names
    |> Enum.filter(
      &(text == &1 or String.starts_with?(text, &1 <> "[") or String.starts_with?(text, &1 <> "{") or
          String.starts_with?(text, &1 <> "|") or String.starts_with?(text, &1 <> "."))
    )
    |> Enum.max_by(&String.length/1, fn -> nil end)
    |> case do
      nil -> nil
      name -> {name, String.replace_prefix(text, name, "")}
    end
  end

  # Follows "[]", "{}", "|n" and ".prop" from the schema at `at`.
  defp descend(_spec, at, ""), do: at

  defp descend(spec, at, "[]" <> rest), do: step(spec, at, ["items"], rest)
  defp descend(spec, at, "{}" <> rest), do: step(spec, at, ["additionalProperties"], rest)

  defp descend(spec, at, "|" <> rest) do
    {digits, rest} = take_digits(rest)
    {at, node} = deref(spec, at)

    case Integer.parse(digits) do
      {n, ""} ->
        union = Enum.find(["oneOf", "anyOf"], &is_list(node[&1]))
        if union, do: descend(spec, at ++ [union, to_string(n - 1)], rest)

      _ ->
        nil
    end
  end

  defp descend(spec, at, "." <> rest) do
    {at, _node} = deref(spec, at)
    {name, rest} = take_name(rest)
    if prop = property_at(spec, at, name, MapSet.new()), do: descend(spec, prop, rest)
  end

  defp descend(_spec, _at, _other), do: nil

  defp step(spec, at, segments, rest) do
    {at, _node} = deref(spec, at)
    next = at ++ segments
    if get(spec, next) != nil, do: descend(spec, next, rest)
  end

  defp take_digits(text) do
    {digits, rest} = text |> String.graphemes() |> Enum.split_while(&(&1 =~ ~r/^\d$/))
    {Enum.join(digits), Enum.join(rest)}
  end

  defp take_name(text) do
    case Regex.run(~r/^([^\[\{\|\.]+)(.*)$/s, text) do
      [_, name, rest] -> {name, rest}
      _ -> {text, ""}
    end
  end

  ## Where a property is defined

  # The pointer of property `name` of the object schema at `at`: its own
  # properties, else its allOf members (later members win when merged, so
  # they are searched first), following $refs.
  defp property_at(spec, at, name, seen) do
    {at, node} = deref(spec, at)

    cond do
      not is_map(node) or MapSet.member?(seen, at) ->
        nil

      is_map(node["properties"]) and Map.has_key?(node["properties"], name) ->
        at ++ ["properties", name]

      is_list(node["allOf"]) ->
        seen = MapSet.put(seen, at)

        node["allOf"]
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {_member, i} ->
          property_at(spec, at ++ ["allOf", to_string(i)], name, seen)
        end)

      true ->
        nil
    end
  end

  # Every object schema (the one at `at` and its allOf members) whose
  # `required` lists `name`.
  defp required_at(spec, at, name, seen) do
    {at, node} = deref(spec, at)

    if not is_map(node) or MapSet.member?(seen, at) do
      []
    else
      seen = MapSet.put(seen, at)
      own = if is_list(node["required"]) and name in node["required"], do: [at], else: []

      members =
        for {_m, i} <- Enum.with_index(node["allOf"] || []),
            p <- required_at(spec, at ++ ["allOf", to_string(i)], name, seen),
            do: p

      Enum.uniq(own ++ members)
    end
  end

  ## Pointers

  # Follows $refs from the node at `segments`: the pointer where the value
  # really is, and the value.
  defp deref(spec, segments, hops \\ 0) do
    case get(spec, segments) do
      %{"$ref" => "#" <> ref} when hops < 32 -> deref(spec, Patch.segments(ref), hops + 1)
      node -> {segments, node}
    end
  end

  defp get(spec, segments) do
    Enum.reduce_while(segments, spec, fn key, node ->
      cond do
        is_map(node) and Map.has_key?(node, key) ->
          {:cont, node[key]}

        is_list(node) ->
          case Integer.parse(key) do
            {i, ""} when i >= 0 and i < length(node) -> {:cont, Enum.at(node, i)}
            _ -> {:halt, nil}
          end

        true ->
          {:halt, nil}
      end
    end)
  end

  defp split_last(text, separator) do
    case String.split(text, separator) do
      [_] -> [text]
      parts -> [parts |> Enum.drop(-1) |> Enum.join(separator), List.last(parts)]
    end
  end

  ## Patches files

  @doc """
  Adds `new` patches to `existing` ones: a patch with the same `op` and
  `path` as an existing one is merged into it (values combined), others are
  appended.
  """
  @spec merge_patches([map], [map]) :: [map]
  def merge_patches(existing, new) do
    Enum.reduce(new, existing, fn patch, acc ->
      case Enum.find_index(acc, &(&1["op"] == patch["op"] and &1["path"] == patch["path"])) do
        nil -> acc ++ [patch]
        i -> List.update_at(acc, i, &combine(&1, patch))
      end
    end)
  end

  defp combine(%{"op" => op} = old, new) when op in ~w(unrequire add_enum),
    do: %{old | "value" => Enum.uniq(old["value"] ++ new["value"])}

  defp combine(%{"op" => "merge"} = old, new),
    do: %{old | "value" => Map.merge(old["value"], new["value"])}

  defp combine(_old, new), do: new

  ## Report for the API's owners

  @doc """
  A Markdown issue for the API's owners: what their spec says, what their
  API returns, where in the spec, and how often it was seen.
  """
  @spec issue([map], String.t()) :: String.t()
  def issue(entries, api_name) do
    rows =
      for %{finding: f, pointer: pointer} <- entries do
        "| `#{pointer || "?"}` | #{says(f)} | #{returns(f)} | #{f["count"]} | #{Enum.map_join(f["operations"] || [], "<br>", &"`#{&1}`")} |"
      end

    """
    ## The #{api_name} OpenAPI spec disagrees with the API's responses

    An SDK generated from the spec compared #{api_name}'s real responses with
    the spec and found #{length(entries)} differences. No response data was
    kept, only the JSON types of the values (and enum values).

    | Where in the spec | The spec says | The API returned | Times seen | Operations |
    |---|---|---|---|---|
    #{Enum.join(rows, "\n")}

    Found with [Infusion](https://github.com/mandar1045/infusion)'s drift
    checking (`Infusion.Runtime.Drift`).
    """
  end

  defp says(%{"kind" => "undocumented_field"}), do: "nothing (not documented)"
  defp says(%{"kind" => "missing_required"}), do: "required"
  defp says(%{"kind" => "unexpected_null"}), do: "not nullable"
  defp says(%{"kind" => "wrong_type", "expected" => e}), do: "type `#{e}`"
  defp says(%{"kind" => "unknown_enum"}), do: "one of the enum values"
  defp says(%{"kind" => "unknown_variant"}), do: "one of the mapped variants"
  defp says(%{"kind" => "unmatched_union"}), do: "one of the union's variants"
  defp says(_), do: ""

  defp returns(%{"kind" => "undocumented_field", "got" => got}),
    do: "a field (#{String.replace(got, "|", " or ")})"

  defp returns(%{"kind" => "missing_required"}), do: "no such field"
  defp returns(%{"kind" => "unexpected_null"}), do: "`null`"

  defp returns(%{"kind" => kind, "got" => got}) when kind in ~w(unknown_enum unknown_variant),
    do: "`#{inspect(got)}`"

  defp returns(%{"got" => got}), do: "#{got}"
end
