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
end
