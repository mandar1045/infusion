defmodule Infusion.Gen.SchemasTest do
  use ExUnit.Case, async: false

  @spec_doc %{
    "openapi" => "3.1.0",
    "paths" => %{},
    "components" => %{
      "schemas" => %{
        "Pet" => %{
          "description" => ~S(A pet. Quotes " and """ and #{interpolation} are safe.),
          "type" => "object",
          "required" => ["id", "kind"],
          "properties" => %{
            "id" => %{"type" => "integer"},
            "kind" => %{"$ref" => "#/components/schemas/Kind"},
            "userId" => %{"type" => "string", "description" => "Owner"},
            "user_id" => %{"type" => ["string", "null"]},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "toy" => %{
              "oneOf" => [%{"$ref" => "#/components/schemas/Ball"}, %{"type" => "string"}]
            }
          }
        },
        "Kind" => %{"type" => "string", "enum" => ["dog", "cat"]},
        "Ball" => %{"type" => "object", "properties" => %{"color" => %{"type" => "string"}}}
      }
    }
  }

  defp generate(document, base) do
    {:ok, resolved} = Infusion.Ref.resolve(document)
    {:ok, normalized, _} = Infusion.Normalize.run(resolved)
    {:ok, ir} = Infusion.IR.build(normalized)
    Infusion.Gen.Schemas.render(ir, base)
  end

  defp compile(files) do
    Code.put_compiler_option(:ignore_module_conflict, true)
    for f <- files, do: Code.compile_string(f.source, f.path)
  end

  test "generates structs that compile and decode JSON" do
    {files, modules} = generate(@spec_doc, "Petstore")

    assert Enum.map(files, & &1.path) |> Enum.sort() ==
             ~w(lib/petstore/schemas/ball.ex lib/petstore/schemas/kind.ex lib/petstore/schemas/pet.ex)

    assert modules["Pet"] == "Petstore.Schemas.Pet"
    compile(files)

    pet =
      Petstore.Schemas.Pet.decode(%{
        "id" => 1,
        "kind" => "dog",
        "userId" => "u1",
        "user_id" => nil,
        "toy" => %{"color" => "red"},
        "tags" => ["good"],
        "vaccinated" => true
      })

    assert %{__struct__: Petstore.Schemas.Pet, id: 1, kind: "dog", tags: ["good"]} = pet
    # "userId" and "user_id" both snake_case to user_id: the property already
    # named user_id keeps it, userId becomes user_id_2.
    assert pet.user_id == nil
    assert pet.user_id_2 == "u1"
    assert %{__struct__: Petstore.Schemas.Ball, color: "red"} = pet.toy
    assert pet.__extra__ == %{"vaccinated" => true}
  end

  test "schemas whose names differ only in punctuation get separate modules and files" do
    doc = %{
      "openapi" => "3.1.0",
      "paths" => %{},
      "components" => %{
        "schemas" => %{
          "api-response-common_failure" => %{"type" => "string"},
          "api-response-common-failure" => %{"type" => "integer"}
        }
      }
    }

    {files, _} = generate(doc, "Cf")
    assert files |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 2

    assert files |> Enum.map(& &1.module) |> Enum.sort() == [
             "Cf.Schemas.ApiResponseCommonFailure",
             "Cf.Schemas.ApiResponseCommonFailure2"
           ]

    compile(files)
  end

  test "inline objects become nested modules" do
    doc = %{
      "openapi" => "3.1.0",
      "paths" => %{},
      "components" => %{
        "schemas" => %{
          "Completion" => %{
            "type" => "object",
            "properties" => %{
              "choices" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "index" => %{"type" => "integer"},
                    "message" => %{
                      "type" => "object",
                      "properties" => %{"content" => %{"type" => "string"}}
                    }
                  }
                }
              },
              "usage" => %{
                "type" => "object",
                "properties" => %{"total" => %{"type" => "integer"}}
              },
              "meta" => %{"type" => "object"}
            }
          }
        }
      }
    }

    {files, _} = generate(doc, "Llm")

    assert files |> Enum.map(& &1.module) |> Enum.sort() == [
             "Llm.Schemas.Completion",
             "Llm.Schemas.Completion.Choice",
             "Llm.Schemas.Completion.Choice.Message",
             "Llm.Schemas.Completion.Usage"
           ]

    compile(files)
    completion = Module.concat(["Llm.Schemas.Completion"])

    result =
      completion.decode(%{
        "choices" => [%{"index" => 0, "message" => %{"content" => "hi"}}],
        "usage" => %{"total" => 3},
        "meta" => %{"k" => 1}
      })

    assert [%{index: 0, message: %{content: "hi"}}] = result.choices
    assert %{total: 3} = result.usage
    # An inline object without fields stays a plain map.
    assert result.meta == %{"k" => 1}
  end

  test "long enums and long descriptions are written in full" do
    values = for i <- 1..300, do: "value_#{i}"
    long = String.duplicate("word ", 2_000)

    doc = %{
      "openapi" => "3.1.0",
      "paths" => %{},
      "components" => %{
        "schemas" => %{"Big" => %{"type" => "string", "enum" => values, "description" => long}}
      }
    }

    {[file], _} = generate(doc, "Wide")
    refute file.source =~ "..."
    compile([file])
    big = Module.concat(["Wide.Schemas.Big"])
    assert {:enum, ^values} = big.__schema__(:type)
  end

  test "the generated code is formatted and documented" do
    {files, _} = generate(@spec_doc, "Petstore")
    pet = Enum.find(files, &(&1.module == "Petstore.Schemas.Pet"))

    assert pet.source =~ "@type t :: %__MODULE__{"
    assert pet.source =~ "id: integer(),"
    assert pet.source =~ "kind: Petstore.Schemas.Kind.t(),"
    assert pet.source =~ "toy: Petstore.Schemas.Ball.t() | String.t() | nil"
    assert pet.source =~ "`user_id_2` (`userId`) - Owner"

    assert pet.source ==
             pet.source |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
  end
end
