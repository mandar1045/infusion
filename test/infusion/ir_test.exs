defmodule Infusion.IRTest do
  use ExUnit.Case, async: true
  alias Infusion.IR
  alias Infusion.IR.{Body, Operation, Param, Schema}

  defp build(paths, schemas \\ %{}) do
    {:ok, ir} = IR.build(%{"paths" => paths, "components" => %{"schemas" => schemas}})
    ir
  end

  test "an operation: names, parameters in path order, body and responses" do
    ir =
      build(%{
        "/repos/{owner}/{repo}/issues" => %{
          "parameters" => [%{"name" => "repo", "in" => "path", "schema" => %{"type" => "string"}}],
          "post" => %{
            "tags" => ["issues"],
            "operationId" => "issues/create",
            "parameters" => [
              %{"name" => "owner", "in" => "path", "schema" => %{"type" => "string"}},
              %{"name" => "X-Request-Id", "in" => "header", "schema" => %{"type" => "string"}},
              %{"name" => "dryRun", "in" => "query", "schema" => %{"type" => "boolean"}}
            ],
            "requestBody" => %{
              "required" => true,
              "content" => %{
                "multipart/form-data" => %{"schema" => %{"type" => "object"}},
                "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/NewIssue"}}
              }
            },
            "responses" => %{
              "201" => %{
                "description" => "Created",
                "content" => %{
                  "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Issue"}}
                }
              }
            }
          }
        }
      })

    assert [%Operation{} = op] = ir.operations
    assert {op.module, op.function, op.method} == {["Issues"], "create", :post}
    assert Enum.map(op.path_params, & &1.name) == ["owner", "repo"]
    assert [%Param{field: "dry_run", location: :query}] = op.query_params
    assert [%Param{name: "X-Request-Id", field: "x_request_id"}] = op.header_params

    assert %Body{
             content_type: "application/json",
             other_content_types: ["multipart/form-data"],
             required?: true,
             schema: %Schema{kind: :ref, ref: "NewIssue"}
           } = op.body

    assert %{"201" => %{schema: %Schema{kind: :ref, ref: "Issue"}, streaming?: false}} =
             op.responses
  end

  test "streaming responses are detected" do
    ir =
      build(%{
        "/chat" => %{
          "post" => %{
            "tags" => ["Chat"],
            "operationId" => "createChat",
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{"schema" => %{}},
                  "text/event-stream" => %{"schema" => %{}}
                }
              }
            }
          }
        }
      })

    assert [%Operation{streaming?: true}] = ir.operations
  end

  test "colliding names are made unique and reported" do
    ir =
      build(%{
        "/v1/customers" => %{"get" => %{"operationId" => "GetCustomers"}},
        "/v1/customers/" => %{"get" => %{"operationId" => "GetCustomersTrailing"}}
      })

    assert ir.operations |> Enum.map(& &1.function) |> Enum.sort() == [
             "list",
             "list_get_customers_trailing"
           ]

    assert [warning] = ir.warnings
    assert warning =~ "Customers.list is taken"
  end

  describe "schemas are classified" do
    setup do
      ir =
        build(%{}, %{
          "Pet" => %{
            "type" => "object",
            "required" => ["name"],
            "additionalProperties" => false,
            "properties" => %{
              "name" => %{"type" => "string"},
              "createdAt" => %{"type" => "string", "format" => "date-time", "readOnly" => true}
            }
          },
          "Labels" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
          "Tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "Shape" => %{
            "oneOf" => [
              %{"$ref" => "#/components/schemas/Circle"},
              %{"$ref" => "#/components/schemas/Square"}
            ],
            "discriminator" => %{
              "propertyName" => "kind",
              "mapping" => %{"circle" => "#/components/schemas/Circle"}
            }
          },
          "Status" => %{"type" => "string", "enum" => ["open", "closed"], "nullable" => true},
          "Kind" => %{"type" => "string", "const" => "pet"},
          "Id" => %{"type" => ["string", "integer"]},
          "Anything" => %{},
          "Odd" => %{"not" => %{"type" => "string"}},
          "EitherOr" => %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}},
            "oneOf" => [%{"required" => ["a"]}, %{"required" => ["b"]}]
          }
        })

      %{s: ir.schemas, warnings: ir.warnings}
    end

    test "objects and their fields", %{s: s} do
      assert %Schema{kind: :object, extra_fields?: false, fields: [created, name]} = s["Pet"]

      assert {created.field, created.read_only?, created.schema.format} ==
               {"created_at", true, "date-time"}

      assert {name.name, name.required?} == {"name", true}
    end

    test "maps, arrays, unions, enums, consts and anything", %{s: s, warnings: warnings} do
      assert %Schema{kind: :map, value: %Schema{kind: :scalar, type: "string"}} = s["Labels"]
      assert %Schema{kind: :array, items: %Schema{kind: :scalar}} = s["Tags"]

      assert %Schema{
               kind: :union,
               variants: [%{kind: :ref, ref: "Circle"}, %{kind: :ref, ref: "Square"}],
               discriminator: %{property: "kind", mapping: %{"circle" => "Circle"}}
             } = s["Shape"]

      assert %Schema{kind: :enum, values: ["open", "closed"], nullable?: true} = s["Status"]
      assert %Schema{kind: :const, const: "pet"} = s["Kind"]
      assert %Schema{kind: :union, variants: [%{type: "string"}, %{type: "integer"}]} = s["Id"]
      assert %Schema{kind: :any} = s["Anything"]
      assert %Schema{kind: :any} = s["Odd"]

      assert Enum.any?(
               warnings,
               &(&1 =~ ~s(components.schemas.Odd: unsupported keywords ["not"]))
             )

      # "either a or b is required" is not a union of types

      assert %Schema{kind: :object, fields: [%{name: "a"}, %{name: "b"}]} = s["EitherOr"]

      refute Enum.any?(warnings, &(&1 =~ "EitherOr"))
    end
  end
end
