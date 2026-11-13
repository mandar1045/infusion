defmodule Infusion.Ref do
  @moduledoc """
  Resolves `$ref`s in an OpenAPI document.

  References to schemas (`#/components/schemas/...`) are kept: each named
  schema becomes its own struct, and keeping the reference is what lets a
  schema refer to itself. Every other reference (parameters, responses,
  request bodies, headers, examples, ...) is replaced by what it points to.

  Rules, from measuring real specs:

    * fields next to a `$ref` (OpenAPI 3.1 allows a `summary` and
      `description` there; OpenAI's spec has 624) override the target's
    * only a `$ref` whose value is a string is a reference: Cloudflare's spec
      has a schema with a property named `$ref`
    * literal data is never read for references: `example`, `default`,
      `enum`, `const`, an example's `value`, a 3.1 schema's `examples` list,
      and `x-` extensions
    * references to other files or URLs are not supported yet (none of the
      surveyed specs use them)
  """

  @schema_prefix "#/components/schemas/"
  @literal_keys ~w(example default enum const)

  @doc """
  Resolves every non-schema reference. Returns an error listing references
  that point nowhere, point to another document, or form a loop.
  """
  @spec resolve(map) :: {:ok, map} | {:error, String.t()}
  def resolve(document) when is_map(document) do
    case problems(document) do
      [] ->
        {resolved, _memo} = inline(document, document, MapSet.new(), %{})
        {:ok, resolved}

      problems ->
        {:error, Enum.join(problems, "\n")}
    end
  catch
    {:ref_cycle, chain} ->
      {:error, "these references form a loop: " <> Enum.join(Enum.reverse(chain), " -> ")}
  end

  @doc "Whether `ref` points at a named schema."
  @spec schema_ref?(String.t()) :: boolean
  def schema_ref?(ref), do: String.starts_with?(ref, @schema_prefix)

  @doc ~S'Returns the schema name of a schema reference: `"#/components/schemas/Pet"` -> `"Pet"`.'
  @spec schema_name(String.t()) :: String.t()
  def schema_name(@schema_prefix <> name), do: unescape(name)

  @doc """
  Returns what a local reference points to, following the JSON Pointer rules
  (`~1` is `/`, `~0` is `~`, and percent-encoding is decoded).
  """
  @spec fetch(map, String.t()) :: {:ok, term} | :error
  def fetch(document, "#" <> pointer) do
    pointer
    |> String.split("/", trim: true)
    |> Enum.reduce_while({:ok, document}, fn token, {:ok, node} ->
      token = unescape(token)

      case node do
        %{^token => value} ->
          {:cont, {:ok, value}}

        list when is_list(list) ->
          case Integer.parse(token) do
            {i, ""} when i >= 0 and i < length(list) -> {:cont, {:ok, Enum.at(list, i)}}
            _ -> {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  def fetch(_document, _ref), do: :error

  defp unescape(token) do
    token |> URI.decode() |> String.replace("~1", "/") |> String.replace("~0", "~")
  end

  ## Finding problems before resolving

  defp problems(document) do
    document
    |> refs([])
    |> Enum.uniq()
    |> Enum.flat_map(fn ref ->
      cond do
        not String.starts_with?(ref, "#") ->
          ["#{ref}: references to other files or URLs are not supported yet"]

        fetch(document, ref) == :error ->
          ["#{ref}: points to nothing in the document"]

        true ->
          []
      end
    end)
  end

  defp refs(%{"$ref" => ref} = map, acc) when is_binary(ref),
    do: refs_in(Map.delete(map, "$ref"), [ref | acc])

  defp refs(map, acc) when is_map(map), do: refs_in(map, acc)
  defp refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &refs/2)
  defp refs(_other, acc), do: acc

  defp refs_in(map, acc) do
    Enum.reduce(map, acc, fn
      {key, _value}, acc when key in @literal_keys ->
        acc

      {"x-" <> _, _value}, acc ->
        acc

      # A map of Example Objects: each may be a reference, its "value" is data.
      {"examples", examples}, acc when is_map(examples) ->
        Enum.reduce(examples, acc, fn
          {_, %{"$ref" => ref}}, acc when is_binary(ref) -> [ref | acc]
          _, acc -> acc
        end)

      # In a 3.1 schema, "examples" is a list of literal values.
      {"examples", examples}, acc when is_list(examples) ->
        acc

      {_key, value}, acc ->
        refs(value, acc)
    end)
  end

  ## Inlining

  # Returns {resolved, memo}; memo caches resolved targets by reference.
  defp inline(%{"$ref" => ref} = map, document, visiting, memo) when is_binary(ref) do
    if schema_ref?(ref) do
      {siblings, memo} = inline_children(Map.delete(map, "$ref"), document, visiting, memo)
      {Map.put(siblings, "$ref", ref), memo}
    else
      if MapSet.member?(visiting, ref), do: throw({:ref_cycle, [ref | MapSet.to_list(visiting)]})

      {target, memo} =
        case memo do
          %{^ref => cached} ->
            {cached, memo}

          _ ->
            {:ok, raw} = fetch(document, ref)
            {target, memo} = inline(raw, document, MapSet.put(visiting, ref), memo)
            {target, Map.put(memo, ref, target)}
        end

      {siblings, memo} = inline_children(Map.delete(map, "$ref"), document, visiting, memo)
      {merge(target, siblings), memo}
    end
  end

  defp inline(map, document, visiting, memo) when is_map(map),
    do: inline_children(map, document, visiting, memo)

  defp inline(list, document, visiting, memo) when is_list(list) do
    Enum.map_reduce(list, memo, &inline(&1, document, visiting, &2))
  end

  defp inline(other, _document, _visiting, memo), do: {other, memo}

  defp inline_children(map, document, visiting, memo) do
    Enum.reduce(map, {%{}, memo}, fn {key, value}, {acc, memo} ->
      {value, memo} =
        cond do
          literal?(key) -> {value, memo}
          key == "examples" and is_map(value) -> inline_examples(value, document, visiting, memo)
          key == "examples" and is_list(value) -> {value, memo}
          true -> inline(value, document, visiting, memo)
        end

      {Map.put(acc, key, value), memo}
    end)
  end

  # An Example Object may be a reference, but its "value" is literal data.
  defp inline_examples(examples, document, visiting, memo) do
    Enum.reduce(examples, {%{}, memo}, fn {name, example}, {acc, memo} ->
      {example, memo} =
        case example do
          %{"$ref" => ref} when is_binary(ref) -> inline(example, document, visiting, memo)
          other -> {other, memo}
        end

      {Map.put(acc, name, example), memo}
    end)
  end

  defp merge(target, siblings) when is_map(target), do: Map.merge(target, siblings)
  defp merge(target, siblings) when siblings == %{}, do: target
  defp merge(target, _siblings), do: target

  defp literal?(key) when key in @literal_keys, do: true
  defp literal?("x-" <> _), do: true
  defp literal?(_), do: false
end
