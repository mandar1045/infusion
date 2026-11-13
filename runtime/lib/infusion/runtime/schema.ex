defmodule Infusion.Runtime.Schema do
  @moduledoc """
  Decodes JSON into the structs of a generated SDK.

  Every generated schema module defines `__schema__/1`:

    * `__schema__(:fields)`: `[{field_atom, "jsonName", type}]`, for objects
    * `__schema__(:type)`: the type, for schemas that aren't objects

  Types:

      :string | :integer | :number | :boolean | :null | :any
      {:ref, module}                      # another schema
      {:array, type}
      {:map, type}                        # string keys to `type`
      {:enum, ["a", "b"]}                 # stays a string
      {:const, value}
      {:union, [type], discriminator}     # discriminator: nil | {"prop", %{"value" => module}}

  Decoding never crashes on data the SDK wasn't generated for: unknown fields
  are kept in `__extra__`, unknown enum values stay strings, and a union
  variant that matches nothing is returned as the raw map.
  """

  @doc "Decodes `json` (already parsed) as `type`."
  @spec decode(term, term) :: term
  def decode(nil, _type), do: nil

  def decode(json, {:ref, module}), do: decode_module(json, module)
  def decode(json, {:array, type}) when is_list(json), do: Enum.map(json, &decode(&1, type))

  def decode(json, {:map, type}) when is_map(json),
    do: Map.new(json, fn {k, v} -> {k, decode(v, type)} end)

  def decode(json, {:union, variants, discriminator}),
    do: decode_union(json, variants, discriminator)

  def decode(json, _type), do: json

  @doc "Decodes `json` as the schema `module`."
  @spec decode_module(term, module) :: term
  def decode_module(json, module) do
    if function_exported?(module, :__struct__, 0) and is_map(json) do
      decode_object(json, module)
    else
      decode(json, module.__schema__(:type))
    end
  end

  defp decode_object(json, module) do
    fields = module.__schema__(:fields)

    {values, present, known} =
      Enum.reduce(fields, {[], [], []}, fn {field, name, type}, {values, present, known} ->
        case Map.fetch(json, name) do
          {:ok, value} ->
            {[{field, decode(value, type)} | values], [field | present], [name | known]}

          :error ->
            {values, present, known}
        end
      end)

    extra = Map.drop(json, known)
    struct(module, values ++ [__extra__: extra, __present__: present])
  end

  ## Unions

  defp decode_union(json, variants, {property, mapping}) when is_map(json) do
    with tag when is_binary(tag) <- Map.get(json, property),
         {:ok, module} <- Map.fetch(mapping, tag) do
      decode_module(json, module)
    else
      _ -> decode_union(json, variants, nil)
    end
  end

  defp decode_union(json, variants, _discriminator) do
    case best_variant(json, variants) do
      nil -> json
      type -> decode(json, type)
    end
  end

  # The variant that fits `json` best: scalar types by the value's own type;
  # objects by how many of their fields are present, with a const field that
  # disagrees (a tag without a discriminator) ruling the variant out.
  defp best_variant(json, variants) do
    variants
    |> Enum.map(&{&1, score(json, &1)})
    |> Enum.reject(fn {_, score} -> score == :no end)
    |> Enum.max_by(fn {_, score} -> score end, fn -> nil end)
    |> case do
      nil -> nil
      {type, _} -> type
    end
  end

  defp score(json, :string) when is_binary(json), do: 1
  defp score(json, :integer) when is_integer(json), do: 1
  defp score(json, :number) when is_number(json), do: 1
  defp score(json, :boolean) when is_boolean(json), do: 1
  defp score(json, {:enum, values}) when is_binary(json), do: if(json in values, do: 2, else: 0)
  defp score(json, {:const, value}), do: if(json == value, do: 3, else: :no)
  defp score(json, {:array, _}) when is_list(json), do: 1
  defp score(json, {:map, _}) when is_map(json), do: 0
  defp score(_json, :any), do: 0

  defp score(json, {:ref, module}) when is_map(json) do
    if function_exported?(module, :__struct__, 0) do
      fields = module.__schema__(:fields)

      mismatch =
        Enum.any?(fields, fn {_, name, type} ->
          match?({:const, _}, type) and Map.has_key?(json, name) and
            score(json[name], type) == :no
        end)

      if mismatch,
        do: :no,
        else: Enum.count(fields, fn {_, name, _} -> Map.has_key?(json, name) end)
    else
      score(json, module.__schema__(:type))
    end
  end

  # Not a map: an object schema can't match it; another named type might.
  defp score(json, {:ref, module}) do
    if function_exported?(module, :__struct__, 0),
      do: :no,
      else: score(json, module.__schema__(:type))
  end

  defp score(json, {:union, variants, _}), do: if(best_variant(json, variants), do: 1, else: :no)
  defp score(_json, _type), do: :no
end
