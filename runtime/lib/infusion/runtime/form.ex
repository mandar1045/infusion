defmodule Infusion.Runtime.Form do
  @moduledoc """
  Encodes nested data as `application/x-www-form-urlencoded`, the way Stripe
  and Twilio expect it.

      iex> Infusion.Runtime.Form.encode(%{"metadata" => %{"order" => "6735"}})
      "metadata%5Border%5D=6735"

  Maps nest with brackets (`metadata[order]=6735`). Lists depend on `style`:

    * `:indexed` (Stripe): `items[0][price]=p_1&expand[0]=customer`
    * `:repeat` (OpenAPI's default, Twilio): `StatusCallbackEvent=a&StatusCallbackEvent=b`

  `nil` values are left out, so an optional parameter that was not given is
  not sent.
  """

  @doc "Encodes `data` (a map or keyword list) as a form body."
  @spec encode(map | keyword, :indexed | :repeat) :: String.t()
  def encode(data, style \\ :indexed) do
    data
    |> pairs(style)
    |> URI.encode_query(:www_form)
  end

  @doc "Flattens `data` into `[{\"key[nested]\", \"value\"}]` pairs."
  @spec pairs(map | keyword, :indexed | :repeat) :: [{String.t(), String.t()}]
  def pairs(data, style \\ :indexed) do
    data
    |> Enum.flat_map(fn {key, value} -> flatten(to_string(key), value, style) end)
  end

  defp flatten(_key, nil, _style), do: []

  defp flatten(key, value, style) when is_map(value) and not is_struct(value) do
    Enum.flat_map(value, fn {k, v} -> flatten("#{key}[#{k}]", v, style) end)
  end

  defp flatten(key, [{k, _} | _] = keyword, style) when is_atom(k) do
    Enum.flat_map(keyword, fn {k, v} -> flatten("#{key}[#{k}]", v, style) end)
  end

  defp flatten(key, list, :indexed) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> flatten("#{key}[#{i}]", v, :indexed) end)
  end

  defp flatten(key, list, :repeat) when is_list(list) do
    Enum.flat_map(list, &flatten(key, &1, :repeat))
  end

  defp flatten(key, value, _style), do: [{key, scalar(value)}]

  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(%{__struct__: _} = value), do: to_string(value)
  defp scalar(value), do: to_string(value)
end
