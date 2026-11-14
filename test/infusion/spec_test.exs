defmodule Infusion.SpecTest do
  use ExUnit.Case, async: true
  alias Infusion.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  test "loads JSON and YAML into the same document" do
    assert {:ok, %Spec{version: "3.1.0", document: json}} =
             Spec.load(Path.join(@fixtures, "petstore.json"))

    assert {:ok, %Spec{version: "3.1.0", document: yaml}} =
             Spec.load(Path.join(@fixtures, "petstore.yaml"))

    assert yaml == json
  end

  test "YAML booleans and nulls are real booleans and nil, and dates stay strings" do
    {:ok, %Spec{document: doc}} = Spec.load(Path.join(@fixtures, "petstore.yaml"))
    pet = doc["components"]["schemas"]["Pet"]

    assert pet["additionalProperties"] == false
    assert pet["properties"]["tag"]["default"] == nil
    assert pet["properties"]["tag"]["type"] == ["string", "null"]
    assert pet["properties"]["born"]["example"] == "2024-01-15"
    # A quoted "true" stays a string.
    assert pet["properties"]["flag"]["example"] == "true"
  end

  test "loads from a URL" do
    body = File.read!(Path.join(@fixtures, "petstore.json"))
    Req.Test.stub(SpecStub, fn conn -> Req.Test.text(conn, body) end)

    assert {:ok, %Spec{source: "https://example.com/openapi.json"}} =
             Spec.load("https://example.com/openapi.json",
               req_options: [plug: {Req.Test, SpecStub}]
             )
  end

  test "explains what went wrong" do
    assert {:error, msg} = Spec.load("missing.json")
    assert msg =~ "could not load missing.json: no such file"

    Req.Test.stub(SpecStub404, &Plug.Conn.send_resp(&1, 404, "nope"))

    assert {:error, msg} =
             Spec.load("https://example.com/x.json",
               req_options: [plug: {Req.Test, SpecStub404}, retry: false]
             )

    assert msg =~ "HTTP 404"
  end

  test "rejects what isn't OpenAPI 3.0 or 3.1" do
    dir = System.tmp_dir!()

    for {name, content, expected} <- [
          {"swagger.json", ~s({"swagger": "2.0"}), "Swagger 2.0"},
          {"v4.json", ~s({"openapi": "4.0.0"}), "OpenAPI 4.0.0 is not supported"},
          {"other.json", ~s({"hello": 1}), "not an OpenAPI document"},
          {"list.json", ~s([1, 2]), "the JSON is not an object"},
          {"broken.json", ~s({"openapi": ), "invalid JSON"}
        ] do
      path = Path.join(dir, "infusion-#{System.unique_integer([:positive])}-#{name}")
      File.write!(path, content)

      try do
        assert {:error, msg} = Spec.load(path)
        assert msg =~ expected, "#{name}: #{msg}"
      after
        File.rm!(path)
      end
    end
  end
end
