defmodule Infusion.RealSpecsTest do
  use ExUnit.Case, async: true
  alias Infusion.Spec

  @moduletag :specs
  @moduletag timeout: 120_000

  defp spec(name), do: Path.join(System.fetch_env!("INFUSION_SPECS"), name)

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  test "OpenAI's YAML and JSON specs load into the same document" do
    {yaml_ms, {:ok, yaml}} = timed(fn -> Spec.load(spec("openai.yaml")) end)
    {json_ms, {:ok, json}} = timed(fn -> Spec.load(spec("openai.json")) end)

    assert yaml.version == "3.1.0"
    assert yaml.document == json.document
    assert json_ms < 2_000
    assert yaml_ms < 30_000
  end

  test "Cloudflare's 28 MB spec loads in seconds" do
    {ms, {:ok, spec}} = timed(fn -> Spec.load(spec("cloudflare.json")) end)
    assert map_size(spec.document["paths"]) > 2_000
    assert ms < 5_000
  end

  @specs ~w(openai.json stripe.json github.json cloudflare.json twilio_api.json)

  test "every reference in five real specs resolves, and only schema references remain" do
    for name <- @specs do
      {:ok, spec} = Spec.load(spec(name))
      {ms, result} = timed(fn -> Infusion.Ref.resolve(spec.document) end)
      assert {:ok, resolved} = result, "#{name}: #{inspect(result)}"

      leftover =
        resolved
        |> refs_outside_literals()
        |> Enum.reject(&Infusion.Ref.schema_ref?/1)

      assert leftover == [],
             "#{name} still has non-schema references: #{inspect(Enum.take(leftover, 3))}"

      assert ms < 15_000, "#{name} took #{ms} ms"
      IO.puts("  #{name}: resolved in #{ms} ms")
    end
  end

  defp refs_outside_literals(%{"$ref" => ref} = map) when is_binary(ref),
    do: [ref | refs_outside_literals(Map.delete(map, "$ref"))]

  defp refs_outside_literals(map) when is_map(map) do
    Enum.flat_map(map, fn
      {key, _} when key in ~w(example default enum const) ->
        []

      {"x-" <> _, _} ->
        []

      {"examples", examples} when is_map(examples) ->
        Enum.flat_map(examples, fn {_, e} -> Map.get(e, "$ref") |> List.wrap() end)

      {_, value} ->
        refs_outside_literals(value)
    end)
  end

  defp refs_outside_literals(list) when is_list(list),
    do: Enum.flat_map(list, &refs_outside_literals/1)

  defp refs_outside_literals(_), do: []
end
