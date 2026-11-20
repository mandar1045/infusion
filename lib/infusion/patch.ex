defmodule Infusion.Patch do
  @moduledoc """
  Fixes a vendor's spec before the SDK is generated from it.

  Specs have mistakes: a field documented as required that the API leaves
  out, a string that is sometimes `null`, a field that isn't documented at
  all. Instead of editing generated code (lost on the next regeneration) or
  forking the spec (lost when the vendor updates it), list the fixes as
  patches. They are applied to the spec as it is loaded, every time, so the
  SDK keeps tracking the vendor's spec with your corrections on top.

  `mix infusion.drift` writes these from what an SDK saw the real API return
  (see `Infusion.Runtime.Drift`); they can also be written by hand. Each
  patch has an `op`, a `path` (a JSON Pointer into the spec, as in
  `$ref`s) and usually a `value`:

    * `merge`: deep-merges `value` (an object) into what's at `path`,
      creating it when only its last part is missing (a new property)
    * `unrequire`: removes the names in `value` from the `required` list of
      the object schema at `path`
    * `add_enum`: adds the values in `value` to the `enum` at `path`
    * `add`, `replace`, `remove`: as in JSON Patch (RFC 6902), for anything
      else

  Any other keys (`reason`, `seen`) are notes and are ignored.

      [
        {"op": "merge", "path": "/components/schemas/repository/properties/license",
         "value": {"nullable": true}, "reason": "null for repos without a license"},
        {"op": "unrequire", "path": "/components/schemas/issue", "value": ["closed_by"]}
      ]

  A patch that no longer applies (the spec has nothing at its path any
  more), or that changes nothing (the spec already says it: the vendor fixed
  their spec), is reported as a warning so it can be removed.
  """

  @ops ~w(merge unrequire add_enum add replace remove)

  @doc """
  Reads patches: a list of patch maps, or the path of a JSON file holding
  one. Keys may be atoms or strings.
  """
  @spec load(nil | Path.t() | [map]) :: {:ok, [map]} | {:error, String.t()}
  def load(nil), do: {:ok, []}

  def load(path) when is_binary(path) do
    with {:ok, text} <- read(path),
         {:ok, patches} <- decode(text, path) do
      load_list(patches, path)
    end
  end

  def load(patches) when is_list(patches), do: load_list(patches, "patches")

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(text, path) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, "#{path}: #{Exception.message(error)}"}
    end
  end

  defp load_list(patches, where) when is_list(patches) do
    patches
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {patch, i}, {:ok, acc} ->
      case normalize(patch) do
        {:ok, patch} -> {:cont, {:ok, [patch | acc]}}
        {:error, message} -> {:halt, {:error, "#{where}: patch #{i}: #{message}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp load_list(_other, where), do: {:error, "#{where}: patches must be a list"}

  defp normalize(patch) when is_map(patch) do
    patch = Map.new(patch, fn {k, v} -> {to_string(k), v} end)
    op = patch["op"] && to_string(patch["op"])

    cond do
      op not in @ops ->
        {:error, "op must be one of #{Enum.join(@ops, ", ")}, got #{inspect(patch["op"])}"}

      not is_binary(patch["path"]) ->
        {:error, "path must be a JSON Pointer string like \"/components/schemas/Pet\""}

      op == "merge" and not is_map(patch["value"]) ->
        {:error, "merge needs an object value"}

      op in ~w(unrequire add_enum) and not is_list(patch["value"]) ->
        {:error, "#{op} needs a list value"}

      op in ~w(add replace) and not Map.has_key?(patch, "value") ->
        {:error, "#{op} needs a value"}

      true ->
        {:ok, Map.put(patch, "op", op)}
    end
  end

  defp normalize(_other), do: {:error, "a patch is an object with op and path"}

  @doc """
  Applies `patches` to the spec `document`, in order. Returns the patched
  document and a warning for every patch that didn't apply or changed
  nothing.
  """
  @spec apply(map, [map]) :: {map, [String.t()]}
  def apply(document, patches) do
    {document, warnings} =
      Enum.reduce(patches, {document, []}, fn patch, {doc, warnings} ->
        case apply_one(doc, patch) do
          {:ok, ^doc} ->
            {doc,
             [
               warning(patch, "the spec already says this (fixed upstream?): remove it")
               | warnings
             ]}

          {:ok, new} ->
            {new, warnings}

          {:error, message} ->
            {doc, [warning(patch, message) | warnings]}
        end
      end)

    {document, Enum.reverse(warnings)}
  end

  defp warning(patch, message),
    do: "infusion.exs: patch #{patch["op"]} #{patch["path"]}: #{message}"

  defp apply_one(doc, %{"op" => op, "path" => path} = patch) do
    segments = segments(path)

    case op do
      "merge" ->
        update(doc, segments, true, fn
          nil -> {:ok, patch["value"]}
          node when is_map(node) -> {:ok, deep_merge(node, patch["value"])}
          _ -> {:error, "not an object there"}
        end)

      "unrequire" ->
        update(doc, segments, false, fn
          node when is_map(node) ->
            {:ok, remove_required(node, patch["value"])}

          _ ->
            {:error, "not a schema there"}
        end)

      "add_enum" ->
        update(doc, segments, false, fn
          %{"enum" => values} = node when is_list(values) ->
            {:ok, %{node | "enum" => values ++ (patch["value"] -- values)}}

          _ ->
            {:error, "no enum there"}
        end)

      "replace" ->
        update(doc, segments, false, fn _ -> {:ok, patch["value"]} end)

      "add" ->
        add(doc, segments, patch["value"])

      "remove" ->
        remove(doc, segments)
    end
  end

  defp remove_required(node, names) do
    case node["required"] do
      list when is_list(list) ->
        case list -- names do
          [] -> Map.delete(node, "required")
          left when left == list -> node
          left -> Map.put(node, "required", left)
        end

      _ ->
        node
    end
  end

  # Calls `fun` with what's at `segments` and puts back what it returns.
  # With `create?`, a missing last segment is passed as nil.
  defp update(node, [], _create?, fun), do: fun.(node)

  defp update(node, [key], true, fun) when is_map(node) and not is_map_key(node, key) do
    with {:ok, value} <- fun.(nil), do: {:ok, Map.put(node, key, value)}
  end

  # A missing "properties" before a new property is created too.
  defp update(node, ["properties", key], true, fun)
       when is_map(node) and not is_map_key(node, "properties") do
    with {:ok, value} <- fun.(nil), do: {:ok, Map.put(node, "properties", %{key => value})}
  end

  defp update(node, [key | rest], create?, fun) when is_map(node) do
    case Map.fetch(node, key) do
      {:ok, child} ->
        with {:ok, child} <- update(child, rest, create?, fun),
             do: {:ok, Map.put(node, key, child)}

      :error ->
        {:error, "the spec has nothing there any more: remove it"}
    end
  end

  defp update(node, [key | rest], create?, fun) when is_list(node) do
    case index(key, node) do
      {:ok, i} ->
        with {:ok, child} <- update(Enum.at(node, i), rest, create?, fun),
             do: {:ok, List.replace_at(node, i, child)}

      :error ->
        {:error, "the spec has nothing there any more: remove it"}
    end
  end

  defp update(_node, _segments, _create?, _fun),
    do: {:error, "the spec has nothing there any more: remove it"}

  defp add(doc, segments, value) do
    {parent, [last]} = Enum.split(segments, -1)

    update(doc, parent, false, fn
      node when is_map(node) ->
        {:ok, Map.put(node, last, value)}

      node when is_list(node) and last == "-" ->
        {:ok, node ++ [value]}

      node when is_list(node) ->
        case index(last, node ++ [nil]) do
          {:ok, i} -> {:ok, List.insert_at(node, i, value)}
          :error -> {:error, "no index #{last} there"}
        end

      _ ->
        {:error, "can't add inside a value"}
    end)
  end

  defp remove(doc, segments) do
    {parent, [last]} = Enum.split(segments, -1)

    update(doc, parent, false, fn
      node when is_map(node) and is_map_key(node, last) ->
        {:ok, Map.delete(node, last)}

      node when is_list(node) ->
        case index(last, node) do
          {:ok, i} -> {:ok, List.delete_at(node, i)}
          :error -> {:error, "the spec has nothing there any more: remove it"}
        end

      _ ->
        {:error, "the spec has nothing there any more: remove it"}
    end)
  end

  defp index(key, list) do
    case Integer.parse(key) do
      {i, ""} when i >= 0 and i < length(list) -> {:ok, i}
      _ -> :error
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, l, r when is_map(l) and is_map(r) -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  @doc """
  Splits a JSON Pointer (`"/a/b~1c"` or `"#/a/b~1c"`) into its unescaped
  segments.
  """
  @spec segments(String.t()) :: [String.t()]
  def segments("#" <> pointer), do: segments(pointer)
  def segments(""), do: []

  def segments("/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end

  def segments(pointer), do: segments("/" <> pointer)

  @doc "Joins segments into a JSON Pointer, escaping `~` and `/`."
  @spec pointer([String.t() | integer]) :: String.t()
  def pointer(segments) do
    Enum.map_join(segments, fn s ->
      "/" <> (s |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1"))
    end)
  end
end
