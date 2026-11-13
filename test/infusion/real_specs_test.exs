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

  test "five real specs normalize: no 3.1 null types left, allOf merged or explained" do
    for name <- @specs do
      {:ok, spec} = Spec.load(spec(name))
      {:ok, resolved} = Infusion.Ref.resolve(spec.document)
      {ms, {:ok, normalized, warnings}} = timed(fn -> Infusion.Normalize.run(resolved) end)

      null_types =
        count(normalized, fn m ->
          match?(%{"type" => t} when is_list(t), m) and "null" in m["type"]
        end)

      false_nullable = count(normalized, &match?(%{"nullable" => false}, &1))
      all_of_before = count(resolved, &Map.has_key?(&1, "allOf"))
      all_of_after = count(normalized, &Map.has_key?(&1, "allOf"))

      assert null_types == 0, "#{name}: #{null_types} type lists still contain null"
      assert false_nullable == 0
      assert ms < 20_000, "#{name} took #{ms} ms"

      kinds =
        warnings
        |> Enum.map(&(&1.message |> String.split(":") |> hd() |> String.slice(0, 45)))
        |> Enum.frequencies()

      IO.puts(
        "  #{name}: #{ms} ms, allOf #{all_of_before} -> #{all_of_after} left, " <>
          "#{length(warnings)} warnings #{inspect(kinds)}"
      )
    end
  end

  test "five real specs go through the whole pipeline into the IR" do
    for name <- @specs do
      {:ok, spec} = Spec.load(spec(name))
      {:ok, resolved} = Infusion.Ref.resolve(spec.document)
      {:ok, normalized, _} = Infusion.Normalize.run(resolved)
      {ms, {:ok, ir}} = timed(fn -> Infusion.IR.build(normalized) end)

      ops = ir.operations
      modules = ops |> Enum.map(& &1.module) |> Enum.uniq() |> length()
      strategies = Enum.frequencies_by(ops, & &1.naming)
      renamed = Enum.count(ir.warnings, &(&1 =~ "is taken"))
      unsupported = Enum.count(ir.warnings, &(&1 =~ "unsupported keywords"))
      kinds = ir.schemas |> Map.values() |> Enum.frequencies_by(& &1.kind)

      assert length(ops) > 100

      assert ops |> Enum.map(&{&1.module, &1.function}) |> Enum.uniq() |> length() == length(ops),
             "#{name}: duplicate names"

      assert ms < 10_000

      IO.puts(
        "  #{name}: #{ms} ms, #{length(ops)} ops in #{modules} modules, naming #{inspect(strategies)}, " <>
          "#{renamed} renamed, #{Enum.count(ops, & &1.streaming?)} streaming, schemas #{inspect(kinds)}, " <>
          "#{unsupported} unsupported, #{length(ir.warnings)} warnings"
      )
    end
  end

  defp count(term, fun) do
    case term do
      %{} = map ->
        self = if fun.(map), do: 1, else: 0

        Enum.reduce(map, self, fn
          {key, _}, acc when key in ~w(example default enum const examples) -> acc
          {"x-" <> _, _}, acc -> acc
          {_, v}, acc -> acc + count(v, fun)
        end)

      list when is_list(list) ->
        Enum.reduce(list, 0, &(&2 + count(&1, fun)))

      _ ->
        0
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
