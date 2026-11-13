defmodule Infusion.Normalize do
  @moduledoc """
  Rewrites the schemas of a resolved document (see `Infusion.Ref`) into one
  canonical form, so the rest of the generator only ever sees one shape.

  ## Nullability

  Real specs say "this can be null" in several ways. All become a single
  `"type"` (when there is one) plus `"nullable" => true`:

    * 3.0: `{"type": "string", "nullable": true}`
    * 3.1: `{"type": ["string", "null"]}`
    * 3.1 unions with null: `{"anyOf": [{"$ref": "..."}, {"type": "null"}]}`
      becomes the other variant, nullable. With several other variants the
      union stays, minus the null variant, and is marked nullable.
    * `null` among an `enum`'s values

  A 3.1 type list with several non-null types (`["string", "integer"]`) stays
  a list.

  ## `allOf`

  A schema built with `allOf` is merged into one schema: properties and
  `required` are combined, referenced members are followed, and the schema's
  own keywords win over its members'. The names of referenced members are
  kept in `"x-infusion-all-of"`.

  When two members define the same property, the later one wins. A warning
  is returned only when they are incompatible: different types, or different
  named schemas. A later member narrowing a loosely defined property (the
  response-envelope pattern, where a shared base declares `result` and each
  endpoint gives it a real type) is intended and stays silent. When a member is itself a union (`oneOf` /
  `anyOf`) the schema can't be merged safely: it is left as it is, with a
  warning.
  """

  alias Infusion.Ref

  @literal_keys ~w(example default enum const examples)

  @type warning :: %{path: String.t(), message: String.t()}

  @doc """
  Normalizes every schema in `document`. Returns the document and the
  warnings found.
  """
  @spec run(map) :: {:ok, map, [warning]}
  def run(document) do
    # First pass: nullability everywhere.
    document = walk(document, &nullability/1)

    # Second pass: allOf, with every component schema available, memoized.
    schemas = get_in(document, ["components", "schemas"]) || %{}
    state = %{schemas: schemas, memo: %{}, warnings: [], stack: []}
    {document, state} = walk_all_of(document, [], state)

    {:ok, document, Enum.reverse(state.warnings)}
  end

  ## Walking every schema-shaped map, skipping literal data

  defp walk(%{} = map, fun) do
    map =
      Map.new(map, fn
        {key, value} when key in @literal_keys -> {key, value}
        {"x-" <> _ = key, value} -> {key, value}
        {key, value} -> {key, walk(value, fun)}
      end)

    fun.(map)
  end

  defp walk(list, fun) when is_list(list), do: Enum.map(list, &walk(&1, fun))
  defp walk(other, _fun), do: other

  ## Nullability

  defp nullability(schema) do
    schema
    |> type_list()
    |> nullable_union("anyOf")
    |> nullable_union("oneOf")
    |> enum_null()
    |> canonical_nullable()
  end

  # 3.1: "type": ["string", "null"]
  defp type_list(%{"type" => types} = schema) when is_list(types) do
    {nulls, others} = Enum.split_with(types, &(&1 == "null"))

    type =
      case others do
        [one] -> one
        [] -> "null"
        many -> many
      end

    schema
    |> Map.put("type", type)
    |> mark_nullable(nulls != [])
  end

  defp type_list(schema), do: schema

  # 3.1: anyOf / oneOf with a {"type": "null"} variant
  defp nullable_union(schema, key) do
    case schema do
      %{^key => variants} when is_list(variants) ->
        {nulls, others} = Enum.split_with(variants, &null_schema?/1)

        cond do
          nulls == [] ->
            schema

          length(others) == 1 ->
            # The union was only "X or null": becomes X, nullable. The
            # schema's own keywords (description, ...) are kept.
            [other] = others

            schema
            |> Map.delete(key)
            |> then(&Map.merge(other, &1))
            |> mark_nullable(true)

          true ->
            schema |> Map.put(key, others) |> mark_nullable(true)
        end

      _ ->
        schema
    end
  end

  defp null_schema?(%{"type" => "null"} = s),
    do: map_size(Map.drop(s, ["type", "description", "title"])) == 0

  defp null_schema?(_), do: false

  defp enum_null(%{"enum" => values} = schema) when is_list(values) do
    if nil in values,
      do: schema |> Map.put("enum", Enum.reject(values, &is_nil/1)) |> mark_nullable(true),
      else: schema
  end

  defp enum_null(schema), do: schema

  # Leave "nullable" only where it is true, as a boolean.
  defp canonical_nullable(%{"nullable" => true} = schema), do: schema
  defp canonical_nullable(%{"nullable" => _} = schema), do: Map.delete(schema, "nullable")
  defp canonical_nullable(schema), do: schema

  defp mark_nullable(schema, true), do: Map.put(schema, "nullable", true)
  defp mark_nullable(schema, false), do: schema

  ## allOf

  defp walk_all_of(%{} = map, path, state) do
    {map, state} =
      Enum.reduce(map, {%{}, state}, fn
        {key, value}, {acc, state} when key in @literal_keys ->
          {Map.put(acc, key, value), state}

        {"x-" <> _ = key, value}, {acc, state} ->
          {Map.put(acc, key, value), state}

        {key, value}, {acc, state} ->
          {value, state} = walk_all_of(value, [key | path], state)
          {Map.put(acc, key, value), state}
      end)

    case map do
      %{"allOf" => members} when is_list(members) -> flatten(map, members, path, state)
      _ -> {map, state}
    end
  end

  defp walk_all_of(list, path, state) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map_reduce(state, fn {item, i}, state -> walk_all_of(item, [i | path], state) end)
  end

  defp walk_all_of(other, _path, state), do: {other, state}

  defp flatten(schema, members, path, state) do
    where = path |> Enum.reverse() |> Enum.join(".")

    {expanded, state} = Enum.map_reduce(members, state, &expand_member(&1, &2, where))

    cond do
      Enum.any?(expanded, &match?({:error, _}, &1)) ->
        {:error, reason} = Enum.find(expanded, &match?({:error, _}, &1))
        {schema, warn(state, where, "allOf not merged: #{reason}")}

      Enum.any?(expanded, fn {:ok, m} -> Map.has_key?(m, "oneOf") or Map.has_key?(m, "anyOf") end) ->
        {schema, warn(state, where, "allOf not merged: a member is a union (oneOf/anyOf)")}

      true ->
        own = Map.delete(schema, "allOf")
        {merged, state} = merge_members(Enum.map(expanded, fn {:ok, m} -> m end), where, state)

        # The schema's own keywords win over its members'. A value must match
        # every member, so it can only be null when the schema itself says so
        # (the 3.0 idiom `allOf: [{$ref: X}], nullable: true`).
        {result, _} = merge_schema(merged, own, :own)

        names = for %{"$ref" => ref} <- members, Ref.schema_ref?(ref), do: Ref.schema_name(ref)

        result =
          result
          |> Map.delete("nullable")
          |> mark_nullable(Map.get(own, "nullable") == true)
          |> then(fn s -> if names == [], do: s, else: Map.put(s, "x-infusion-all-of", names) end)

        {result, state}
    end
  end

  # A member reference is followed (and its own allOf flattened first).
  defp expand_member(%{"$ref" => ref} = member, state, _where) when is_binary(ref) do
    cond do
      not Ref.schema_ref?(ref) ->
        {{:ok, Map.delete(member, "$ref")}, state}

      ref in state.stack ->
        {{:error,
          "it refers to itself through #{Enum.join(Enum.reverse([ref | state.stack]), " -> ")}"},
         state}

      Map.has_key?(state.memo, ref) ->
        {{:ok, Map.merge(state.memo[ref], Map.delete(member, "$ref"))}, state}

      true ->
        name = Ref.schema_name(ref)
        target = Map.get(state.schemas, name, %{})

        {flat, state} =
          walk_all_of(target, [name, "schemas", "components"], %{
            state
            | stack: [ref | state.stack]
          })

        state = %{state | stack: tl(state.stack), memo: Map.put(state.memo, ref, flat)}
        {{:ok, Map.merge(flat, Map.delete(member, "$ref"))}, state}
    end
  end

  defp expand_member(%{} = member, state, _where), do: {{:ok, member}, state}
  defp expand_member(_other, state, _where), do: {{:error, "a member is not a schema"}, state}

  defp merge_members(members, where, state) do
    Enum.reduce(members, {%{}, state}, fn member, {acc, state} ->
      {merged, conflicts} = merge_schema(acc, member, :member)
      {merged, Enum.reduce(conflicts, state, &warn(&2, where, &1))}
    end)
  end

  # Returns {merged, conflict_messages}. Conflicts are only reported between
  # members; the schema's own keywords override silently.
  defp merge_schema(base, extra, mode) do
    Enum.reduce(extra, {base, []}, fn
      {"properties", props}, {acc, conflicts} when is_map(props) ->
        existing = Map.get(acc, "properties", %{})

        new_conflicts =
          for {name, schema} <- props,
              mode == :member and Map.has_key?(existing, name),
              reason = incompatible(existing[name], schema),
              do: "property #{inspect(name)}: #{reason}; the later member wins"

        {Map.put(acc, "properties", Map.merge(existing, props)), conflicts ++ new_conflicts}

      {"required", required}, {acc, conflicts} when is_list(required) ->
        {Map.put(acc, "required", Enum.uniq(Map.get(acc, "required", []) ++ required)), conflicts}

      {"type", type}, {acc, conflicts} ->
        case acc do
          %{"type" => existing} when existing != type and mode == :member ->
            {Map.put(acc, "type", type),
             conflicts ++
               ["members disagree on the type (#{inspect(existing)} vs #{inspect(type)})"]}

          _ ->
            {Map.put(acc, "type", type), conflicts}
        end

      {"additionalProperties", false}, {acc, conflicts} ->
        {Map.put(acc, "additionalProperties", false), conflicts}

      {"nullable", _}, {acc, conflicts} ->
        {acc, conflicts}

      {key, value}, {acc, conflicts} ->
        {Map.put(acc, key, value), conflicts}
    end)
  end

  # Only real disagreements are reported. A later member narrowing a loosely
  # defined property (the response-envelope pattern: `result` declared
  # loosely by a shared base, then given its real type per endpoint) is
  # intended, and so are differences in documentation or format.
  defp incompatible(%{"$ref" => a}, %{"$ref" => b}) when a != b,
    do: "two members refer to different schemas (#{Ref.schema_name(a)}, #{Ref.schema_name(b)})"

  defp incompatible(%{"type" => a}, %{"type" => b})
       when a != b and not is_nil(a) and not is_nil(b),
       do: "two members give different types (#{inspect(a)}, #{inspect(b)})"

  defp incompatible(_earlier, _later), do: nil

  defp warn(state, where, message),
    do: %{state | warnings: [%{path: where, message: message} | state.warnings]}
end
