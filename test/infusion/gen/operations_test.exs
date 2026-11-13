defmodule Infusion.Gen.OperationsTest do
  # Generates a small SDK, compiles it, and calls it against a Req.Test stub.
  use ExUnit.Case, async: false

  @spec_doc %{
    "openapi" => "3.0.3",
    "info" => %{"title" => "Pet Store", "version" => "2.0"},
    "servers" => [
      %{
        "url" => "https://{region}.pets.test/v2",
        "variables" => %{"region" => %{"default" => "eu"}}
      }
    ],
    "security" => [%{"key" => []}],
    "components" => %{
      "securitySchemes" => %{
        "key" => %{"type" => "apiKey", "in" => "header", "name" => "X-Pet-Key"}
      },
      "schemas" => %{
        "Pet" => %{
          "type" => "object",
          "required" => ["id"],
          "properties" => %{"id" => %{"type" => "string"}, "name" => %{"type" => "string"}}
        },
        "NewPet" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{
            "name" => %{"type" => "string", "description" => "What to call it"},
            "limit" => %{"type" => "integer"}
          }
        }
      }
    },
    "paths" => %{
      "/pets" => %{
        "get" => %{
          "operationId" => "listPets",
          "summary" => "List pets",
          "parameters" => [
            %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer"}},
            %{"name" => "X-Trace", "in" => "header", "schema" => %{"type" => "string"}}
          ],
          "responses" => %{
            "200" => %{
              "description" => "ok",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "array",
                    "items" => %{"$ref" => "#/components/schemas/Pet"}
                  }
                }
              }
            }
          }
        },
        "post" => %{
          "operationId" => "createPet",
          "parameters" => [
            %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer"}}
          ],
          "requestBody" => %{
            "content" => %{
              "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/NewPet"}}
            }
          },
          "responses" => %{
            "201" => %{
              "description" => "created",
              "content" => %{
                "application/json" => %{"schema" => %{"$ref" => "#/components/schemas/Pet"}}
              }
            }
          }
        }
      },
      "/pets/{end}" => %{
        "parameters" => [
          %{
            "name" => "end",
            "in" => "path",
            "required" => true,
            "schema" => %{"type" => "string"}
          }
        ],
        "delete" => %{
          "operationId" => "deletePet",
          "deprecated" => true,
          "responses" => %{"204" => %{"description" => "gone"}}
        }
      },
      "/pets/{petId}/photo" => %{
        "get" => %{
          "operationId" => "getPhoto",
          "parameters" => [
            %{
              "name" => "petId",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string"}
            }
          ],
          "responses" => %{
            "200" => %{
              "description" => "jpeg",
              "content" => %{
                "image/jpeg" => %{"schema" => %{"type" => "string", "format" => "binary"}}
              }
            }
          }
        },
        "put" => %{
          "operationId" => "uploadPhoto",
          "servers" => [%{"url" => "https://uploads.pets.test"}],
          "parameters" => [
            %{
              "name" => "petId",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string"}
            }
          ],
          "requestBody" => %{
            "content" => %{
              "image/jpeg" => %{"schema" => %{"type" => "string", "format" => "binary"}}
            }
          },
          "responses" => %{"204" => %{"description" => "stored"}}
        }
      },
      "/adoptions" => %{
        "post" => %{
          "operationId" => "adopt",
          "tags" => ["Adoptions"],
          "requestBody" => %{
            "content" => %{
              "application/x-www-form-urlencoded" => %{
                "schema" => %{
                  "type" => "object",
                  "properties" => %{
                    "pet" => %{"type" => "string"},
                    "metadata" => %{"type" => "object"}
                  }
                }
              }
            }
          },
          "responses" => %{
            "200" => %{
              "description" => "ok",
              "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}
            }
          }
        }
      }
    }
  }

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "infusion_petstore_#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(@spec_doc))
    {:ok, result} = Infusion.generate(path, name: "PetStore")
    File.rm!(path)

    Code.put_compiler_option(:ignore_module_conflict, true)

    # A real SDK is its own (loaded) app, which is where its config is read.
    :ok =
      :application.load(
        {:application, :petstore_sdk,
         [
           description: ~c"test",
           vsn: ~c"0.1.0",
           modules: [],
           registered: [],
           applications: [],
           env: []
         ]}
      )

    {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
      result.files
      |> Enum.filter(&(&1.module && String.ends_with?(&1.path, ".ex")))
      |> Enum.map(fn f ->
        file =
          Path.join(System.tmp_dir!(), "infusion_gen_#{System.unique_integer([:positive])}.ex")

        File.write!(file, f.source)
        file
      end)
      |> Kernel.ParallelCompiler.compile(return_diagnostics: true)

    %{result: result}
  end

  # The generated modules don't exist when this file compiles.
  defp sdk(""), do: Module.concat(["PetStore"])
  defp sdk(name), do: Module.concat(["PetStore" | String.split(name, ".")])

  setup do
    test = self()
    Application.put_env(:petstore_sdk, :req_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:petstore_sdk, :api_key, "pk-1")
    Application.put_env(:petstore_sdk, :sleep, fn ms -> send(test, {:slept, ms}) end)
    on_exit(fn -> Application.delete_env(:petstore_sdk, :req_options) end)
    Req.Test.verify_on_exit!()
    :ok
  end

  test "project files", %{result: result} do
    paths = Enum.map(result.files, & &1.path)

    for path <-
          ~w(mix.exs .formatter.exs .gitignore README.md lib/petstore.ex lib/petstore/pets.ex lib/petstore/adoptions.ex lib/petstore/schemas/pet.ex) do
      assert path in paths
    end

    mix = Enum.find(result.files, &(&1.path == "mix.exs")).source
    assert mix =~ "app: :petstore_sdk"
    assert mix =~ ~s({:infusion_runtime, "~> 0.1"})

    pets = Enum.find(result.files, &(&1.path == "lib/petstore/pets.ex")).source
    assert pets =~ ~s(@doc """)
    assert pets =~ "@deprecated"
  end

  test "the client's defaults come from the spec" do
    config = sdk("").config()
    assert config.base_url == "https://eu.pets.test/v2"
    assert config.auth == {:header, "X-Pet-Key"}
    assert config.user_agent =~ "petstore_sdk/0.1.0"
  end

  test "query and header parameters, a list response of structs" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "eu.pets.test"
      assert conn.request_path == "/v2/pets"
      assert conn.query_string == "limit=2"
      assert Plug.Conn.get_req_header(conn, "x-trace") == ["t-1"]
      assert Plug.Conn.get_req_header(conn, "x-pet-key") == ["pk-1"]
      Req.Test.json(conn, [%{"id" => "1", "name" => "Rex"}, %{"id" => "2"}])
    end)

    assert {:ok,
            [
              %{__struct__: PetStore.Schemas.Pet, id: "1", name: "Rex"},
              %{__struct__: PetStore.Schemas.Pet, id: "2"}
            ]} =
             sdk("Pets").list(limit: 2, x_trace: "t-1")
  end

  test "a body field and a query parameter with the same name don't collide" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.query_string == "limit=5"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"name" => "Rex", "limit" => 1}
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "9", "name" => "Rex"})
    end)

    assert %{__struct__: PetStore.Schemas.Pet, id: "9"} =
             sdk("Pets").create!(name: "Rex", limit: 5, limit_body: 1)
  end

  test "a path parameter named like a keyword; an empty response" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v2/pets/a%2Fb"
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, nil} = sdk("Pets").delete("a/b")
  end

  test "binary bodies and responses; a per-operation server" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "uploads.pets.test"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["image/jpeg"]
      assert {:ok, <<0xFF, 0xD8>>, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert {:ok, nil} = sdk("Pets.Photo").update("p1", <<0xFF, 0xD8>>)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, <<0xFF, 0xD8>>)
    end)

    assert {:ok, <<0xFF, 0xD8>>} = sdk("Pets.Photo").retrieve("p1")
  end

  test "form bodies" do
    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_www_form(body) == "metadata[source]=shelter&pet=p1"
      Req.Test.json(conn, %{"ok" => true})
    end)

    assert {:ok, %{"ok" => true}} =
             sdk("Adoptions").adopt(pet: "p1", metadata: %{source: "shelter"})
  end

  test "errors are typed and retried like the official SDKs" do
    Req.Test.expect(__MODULE__, 3, &Plug.Conn.send_resp(&1, 503, "down"))

    assert {:error, %Infusion.Runtime.Error{type: :internal_server, status: 503}} =
             sdk("Pets").list()

    assert_received {:slept, _}
    assert_received {:slept, _}
    refute_received {:slept, _}
  end
end
