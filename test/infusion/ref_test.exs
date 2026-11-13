defmodule Infusion.RefTest do
  use ExUnit.Case, async: true
  alias Infusion.Ref

  defp doc(paths, components),
    do: %{"openapi" => "3.1.0", "paths" => paths, "components" => components}

  test "inlines parameters, responses and request bodies; keeps schema references" do
    document =
      doc(
        %{
          "/pets/{id}" => %{
            "get" => %{
              "parameters" => [%{"$ref" => "#/components/parameters/Id"}],
              "responses" => %{"404" => %{"$ref" => "#/components/responses/NotFound"}}
            }
          }
        },
        %{
          "parameters" => %{
            "Id" => %{"name" => "id", "in" => "path", "schema" => %{"type" => "string"}}
          },
          "responses" => %{
            "NotFound" => %{
              "description" => "Not found",
              "content" => %{
                "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Error"}}
              }
            }
          },
          "schemas" => %{"Error" => %{"type" => "object"}}
        }
      )

    assert {:ok, resolved} = Ref.resolve(document)
    op = resolved["paths"]["/pets/{id}"]["get"]

    assert op["parameters"] == [
             %{"name" => "id", "in" => "path", "schema" => %{"type" => "string"}}
           ]

    assert op["responses"]["404"]["content"]["application/json"]["schema"] == %{
             "$ref" => "#/components/schemas/Error"
           }
  end

  test "fields next to a reference override the target's" do
    document =
      doc(
        %{
          "/a" => %{
            "get" => %{
              "responses" => %{
                "200" => %{"$ref" => "#/components/responses/Ok", "description" => "Local"}
              }
            }
          }
        },
        %{
          "responses" => %{"Ok" => %{"description" => "Shared", "headers" => %{}}}
        }
      )

    assert {:ok, resolved} = Ref.resolve(document)

    assert resolved["paths"]["/a"]["get"]["responses"]["200"] == %{
             "description" => "Local",
             "headers" => %{}
           }
  end

  test "follows chains of references" do
    document =
      doc(
        %{
          "/a" => %{
            "get" => %{"responses" => %{"200" => %{"$ref" => "#/components/responses/A"}}}
          }
        },
        %{
          "responses" => %{
            "A" => %{"$ref" => "#/components/responses/B"},
            "B" => %{"description" => "end"}
          }
        }
      )

    assert {:ok,
            %{
              "paths" => %{
                "/a" => %{"get" => %{"responses" => %{"200" => %{"description" => "end"}}}}
              }
            }} =
             Ref.resolve(document)
  end

  test "reports loops instead of hanging" do
    document =
      doc(
        %{
          "/a" => %{
            "get" => %{"responses" => %{"200" => %{"$ref" => "#/components/responses/A"}}}
          }
        },
        %{
          "responses" => %{
            "A" => %{"$ref" => "#/components/responses/B"},
            "B" => %{"$ref" => "#/components/responses/A"}
          }
        }
      )

    assert {:error, msg} = Ref.resolve(document)
    assert msg =~ "form a loop"
    assert msg =~ "#/components/responses/A"
  end

  test "self-referencing schemas are fine: they stay references" do
    document =
      doc(%{}, %{
        "schemas" => %{
          "Node" => %{"properties" => %{"child" => %{"$ref" => "#/components/schemas/Node"}}}
        }
      })

    assert {:ok, resolved} = Ref.resolve(document)

    assert resolved["components"]["schemas"]["Node"]["properties"]["child"] == %{
             "$ref" => "#/components/schemas/Node"
           }
  end

  test "lists references that point nowhere or to other documents" do
    document =
      doc(
        %{
          "/a" => %{
            "get" => %{
              "responses" => %{
                "200" => %{"$ref" => "#/components/responses/Missing"},
                "400" => %{"$ref" => "common.yaml#/Err"}
              }
            }
          }
        },
        %{}
      )

    assert {:error, msg} = Ref.resolve(document)
    assert msg =~ "#/components/responses/Missing: points to nothing"
    assert msg =~ "common.yaml#/Err: references to other files or URLs are not supported yet"
  end

  test "JSON Pointer escapes and percent-encoding" do
    document = %{"paths" => %{"/a/{b}" => %{"get" => %{"x" => 1}}}, "c~d" => [10, 20]}
    assert Ref.fetch(document, "#/paths/~1a~1%7Bb%7D/get/x") == {:ok, 1}
    assert Ref.fetch(document, "#/c~0d/1") == {:ok, 20}
    assert Ref.fetch(document, "#/c~0d/5") == :error
    assert Ref.schema_name("#/components/schemas/Foo~1Bar") == "Foo/Bar"
  end

  test "a property named $ref, and $ref inside literal data, are left alone" do
    property_named_ref = %{"type" => "object", "properties" => %{"$ref" => %{"type" => "string"}}}
    literal = %{"$ref" => "#/does/not/exist"}

    document =
      doc(%{}, %{
        "schemas" => %{
          "Odd" => property_named_ref,
          "Ex" => %{
            "type" => "object",
            "example" => literal,
            "default" => literal,
            "x-meta" => literal
          },
          "WithExamples" => %{"examples" => %{"one" => %{"value" => literal}}},
          "Schema31" => %{"type" => "object", "examples" => [literal]}
        }
      })

    assert {:ok, resolved} = Ref.resolve(document)
    assert resolved["components"]["schemas"]["Odd"] == property_named_ref
    assert resolved["components"]["schemas"]["Ex"]["example"] == literal

    assert resolved["components"]["schemas"]["WithExamples"]["examples"]["one"]["value"] ==
             literal

    assert resolved["components"]["schemas"]["Schema31"]["examples"] == [literal]
  end
end
