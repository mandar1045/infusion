defmodule Infusion.NormalizeTest do
  use ExUnit.Case, async: true
  alias Infusion.Normalize

  defp normalize(schemas) do
    {:ok, doc, warnings} = Normalize.run(%{"components" => %{"schemas" => schemas}})
    {doc["components"]["schemas"], warnings}
  end

  defp schema(s), do: normalize(%{"S" => s}) |> elem(0) |> Map.fetch!("S")

  describe "nullability" do
    test "3.0 nullable and 3.1 type lists become the same thing" do
      assert schema(%{"type" => "string", "nullable" => true}) == %{
               "type" => "string",
               "nullable" => true
             }

      assert schema(%{"type" => ["string", "null"]}) == %{"type" => "string", "nullable" => true}
    end

    test "nullable: false is dropped" do
      assert schema(%{"type" => "string", "nullable" => false}) == %{"type" => "string"}
    end

    test "several non-null types stay a list" do
      assert schema(%{"type" => ["string", "integer", "null"]}) == %{
               "type" => ["string", "integer"],
               "nullable" => true
             }
    end

    test "X or null becomes X, nullable, keeping the schema's own description" do
      s =
        schema(%{
          "description" => "The pet",
          "anyOf" => [%{"$ref" => "#/components/schemas/Pet"}, %{"type" => "null"}]
        })

      assert s == %{
               "$ref" => "#/components/schemas/Pet",
               "nullable" => true,
               "description" => "The pet"
             }
    end

    test "a union of several types and null stays a union, nullable" do
      s =
        schema(%{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "null"}]})

      assert s == %{
               "oneOf" => [%{"type" => "string"}, %{"type" => "integer"}],
               "nullable" => true
             }
    end

    test "null among enum values" do
      assert schema(%{"type" => "string", "enum" => ["a", "b", nil]}) == %{
               "type" => "string",
               "enum" => ["a", "b"],
               "nullable" => true
             }
    end

    test "nested schemas are normalized too, literal data isn't" do
      s =
        schema(%{
          "type" => "object",
          "properties" => %{
            "tags" => %{"type" => "array", "items" => %{"type" => ["string", "null"]}}
          },
          "example" => %{"type" => ["string", "null"]}
        })

      assert s["properties"]["tags"]["items"] == %{"type" => "string", "nullable" => true}
      assert s["example"] == %{"type" => ["string", "null"]}
    end
  end

  describe "allOf" do
    setup do
      %{
        base: %{
          "type" => "object",
          "required" => ["id"],
          "properties" => %{"id" => %{"type" => "string"}, "created" => %{"type" => "integer"}}
        }
      }
    end

    test "merges referenced members, combining properties and required", %{base: base} do
      {schemas, []} =
        normalize(%{
          "Base" => base,
          "Pet" => %{
            "description" => "A pet",
            "allOf" => [
              %{"$ref" => "#/components/schemas/Base"},
              %{
                "type" => "object",
                "required" => ["name"],
                "properties" => %{"name" => %{"type" => "string"}}
              }
            ]
          }
        })

      pet = schemas["Pet"]
      refute Map.has_key?(pet, "allOf")
      assert pet["description"] == "A pet"
      assert pet["type"] == "object"
      assert Enum.sort(pet["required"]) == ["id", "name"]
      assert Map.keys(pet["properties"]) |> Enum.sort() == ["created", "id", "name"]
      assert pet["x-infusion-all-of"] == ["Base"]
    end

    test "follows members that are themselves built with allOf", %{base: base} do
      {schemas, []} =
        normalize(%{
          "Base" => base,
          "Middle" => %{
            "allOf" => [
              %{"$ref" => "#/components/schemas/Base"},
              %{"properties" => %{"m" => %{"type" => "boolean"}}}
            ]
          },
          "Top" => %{
            "allOf" => [
              %{"$ref" => "#/components/schemas/Middle"},
              %{"properties" => %{"t" => %{"type" => "number"}}}
            ]
          }
        })

      assert Map.keys(schemas["Top"]["properties"]) |> Enum.sort() == ["created", "id", "m", "t"]
    end

    test "the 3.0 idiom allOf: [ref], nullable: true is a nullable ref", %{base: base} do
      {schemas, []} =
        normalize(%{
          "Base" => base,
          "Maybe" => %{"allOf" => [%{"$ref" => "#/components/schemas/Base"}], "nullable" => true}
        })

      assert schemas["Maybe"]["nullable"] == true
      assert schemas["Maybe"]["properties"]["id"] == %{"type" => "string"}
    end

    test "conflicting members: the later wins, with a warning", %{base: base} do
      {schemas, [warning]} =
        normalize(%{
          "Base" => base,
          "Narrow" => %{
            "allOf" => [
              %{"$ref" => "#/components/schemas/Base"},
              %{"properties" => %{"id" => %{"type" => "integer"}}}
            ]
          }
        })

      assert schemas["Narrow"]["properties"]["id"] == %{"type" => "integer"}
      assert warning.path == "components.schemas.Narrow"
      assert warning.message =~ ~s(property "id": two members give different types)
    end

    test "narrowing a loose property, or changing only its docs, is not a conflict" do
      {schemas, []} =
        normalize(%{
          "Envelope" => %{
            "type" => "object",
            "properties" => %{
              "result" => %{"type" => "object"},
              "note" => %{"type" => "string", "description" => "a"}
            }
          },
          "PetResponse" => %{
            "allOf" => [
              %{"$ref" => "#/components/schemas/Envelope"},
              %{
                "properties" => %{
                  "result" => %{"$ref" => "#/components/schemas/Pet"},
                  "note" => %{"type" => "string", "description" => "b"}
                }
              }
            ]
          }
        })

      assert schemas["PetResponse"]["properties"]["result"] == %{
               "$ref" => "#/components/schemas/Pet"
             }
    end

    test "a member that is a union is not merged, with a warning" do
      original = %{
        "allOf" => [
          %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]},
          %{"description" => "x"}
        ]
      }

      {schemas, [warning]} = normalize(%{"U" => original})
      assert schemas["U"] == original
      assert warning.message =~ "a member is a union"
    end

    test "a schema that includes itself is reported, not looped on" do
      {_schemas, warnings} =
        normalize(%{"Loop" => %{"allOf" => [%{"$ref" => "#/components/schemas/Loop"}]}})

      assert Enum.any?(warnings, &(&1.message =~ "refers to itself"))
    end
  end
end
