defmodule Infusion.ConfigTest do
  use ExUnit.Case, async: true

  alias Infusion.{Config, IR}

  @doc_spec %{
    "openapi" => "3.0.3",
    "info" => %{"title" => "Shop", "version" => "1"},
    "paths" => %{
      "/webhook_endpoints" => %{
        "get" => %{
          "operationId" => "listWebhookEndpoints",
          "parameters" => [
            %{"name" => "page", "in" => "query", "schema" => %{"type" => "integer"}}
          ],
          "responses" => %{
            "200" => %{
              "description" => "ok",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "entries" => %{"type" => "array", "items" => %{"type" => "string"}},
                      "others" => %{"type" => "array", "items" => %{"type" => "integer"}},
                      "next" => %{"type" => "string"}
                    }
                  }
                }
              }
            }
          }
        }
      },
      "/webhook_endpoints/{id}/events" => %{
        "get" => %{
          "operationId" => "listEndpointEvents",
          "parameters" => [
            %{
              "name" => "id",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string"}
            }
          ],
          "responses" => %{"204" => %{"description" => "none"}}
        }
      },
      "/user" => %{
        "get" => %{
          "operationId" => "users/get-authenticated",
          "responses" => %{"204" => %{"description" => "none"}}
        }
      },
      "/users/{name}" => %{
        "get" => %{
          "operationId" => "users/get-by-name",
          "parameters" => [
            %{
              "name" => "name",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string"}
            }
          ],
          "responses" => %{"204" => %{"description" => "none"}}
        }
      }
    }
  }

  setup_all do
    {:ok, ir} = IR.build(@doc_spec)
    %{ir: ir}
  end

  defp names(ir),
    do: ir.operations |> Enum.map(&Enum.join(&1.module ++ [&1.function], ".")) |> Enum.sort()

  describe "validate/1" do
    test "accepts a full config" do
      assert :ok =
               Config.validate(
                 name: GitHub,
                 spec: "spec.json",
                 auth: {:header, "x-api-key"},
                 headers: %{"x-version" => "1"},
                 max_retries: 3,
                 rename: %{"GET /user" => "Users.me", "x" => "get"},
                 rename_modules: %{"Apps" => "GitHub.Apps"},
                 pagination: %{"a" => false, "b" => [style: :cursor, param: "c", from: "meta.c"]}
               )
    end

    test "says what is wrong" do
      for {config, message} <- [
            {[colour: :red], "unknown key :colour"},
            {[auth: :token], ":auth must be :bearer"},
            {[name: "github"], ":name must be a module name"},
            {[headers: [{"a", 1}]], ":headers must be"},
            {[rename: %{"GET /user" => "Users.Me"}], ~s(give "Module.function")},
            {[rename: %{"GET /user" => "users.me"}], ~s(give "Module.function")},
            {[rename_modules: %{"apps" => "Apps"}], "both must be module names"},
            {[pagination: %{"x" => [style: :pages]}], ":style must be one of"},
            {[pagination: %{"x" => [style: :cursor, param: "c"]}], "needs :from"},
            {[pagination: %{"x" => [style: :page, size: "n"]}], "unknown :size"},
            {[pagination: %{"x" => true}], "give false or a keyword list"},
            {%{name: "A"}, "must be a keyword list"}
          ] do
        assert {:error, error} = Config.validate(config)
        assert error =~ message, "#{inspect(config)}: #{error}"
      end
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "reads the file and makes paths relative to it", %{tmp_dir: dir} do
      path = Path.join(dir, "infusion.exs")

      File.write!(
        path,
        ~s([name: "Shop", spec: "specs/shop.json", out: "..", base_url: "https://x.test"])
      )

      assert {:ok, config} = Config.load(path)
      assert config[:spec] == Path.join(dir, "specs/shop.json")
      assert config[:out] == Path.dirname(dir)
      assert config[:base_url] == "https://x.test"
    end

    @tag :tmp_dir
    test "keeps URLs and reports bad files", %{tmp_dir: dir} do
      path = Path.join(dir, "infusion.exs")
      File.write!(path, ~s([name: "Shop", spec: "https://x.test/spec.json"]))
      assert {:ok, [name: "Shop", spec: "https://x.test/spec.json"]} = Config.load(path)

      File.write!(path, "[name: ")
      assert {:error, message} = Config.load(path)
      assert message =~ path

      File.write!(path, ~s([nme: "Shop"]))
      assert {:error, "infusion.exs: unknown key :nme" <> _} = Config.load(path)

      assert {:error, message} = Config.load(Path.join(dir, "missing.exs"))
      assert message =~ "no such file"
    end
  end

  describe "apply/2" do
    test "renames by method and path, operation ID, or generated name", %{ir: ir} do
      before = names(ir)
      assert "Users.get_authenticated" in before
      assert "Users.get_by_name" in before

      assert {:ok, ir, []} =
               Config.apply(ir,
                 rename: %{
                   "GET /user" => "Users.me",
                   "users/get-by-name" => "Accounts.fetch",
                   "WebhookEndpoints.list" => "all"
                 }
               )

      assert "Users.me" in names(ir)
      assert "Accounts.fetch" in names(ir)
      assert "WebhookEndpoints.all" in names(ir)
    end

    test "renames modules with everything under them", %{ir: ir} do
      assert "WebhookEndpoints.Events.list" in names(ir)

      assert {:ok, ir, []} = Config.apply(ir, rename_modules: %{"WebhookEndpoints" => "Webhooks"})
      assert "Webhooks.list" in names(ir)
      assert "Webhooks.Events.list" in names(ir)

      # The longest prefix wins.
      {:ok, ir2} = IR.build(@doc_spec)

      assert {:ok, ir2, []} =
               Config.apply(ir2,
                 rename_modules: %{
                   "WebhookEndpoints" => "Webhooks",
                   "WebhookEndpoints.Events" => "Events"
                 }
               )

      assert "Events.list" in names(ir2)
      assert "Webhooks.list" in names(ir2)
    end

    test "warns about names that match nothing", %{ir: ir} do
      assert {:ok, _ir, warnings} =
               Config.apply(ir,
                 rename: %{"get /user" => "me", "nope" => "x"},
                 rename_modules: %{"Nope" => "Yes"},
                 pagination: %{"Nope.list" => false}
               )

      assert [
               ~s(infusion.exs rename_modules: "Nope" matches no module),
               ~s[infusion.exs rename: "get /user" matches no operation (methods are written in capitals, like "GET /path")],
               ~s(infusion.exs rename: "nope" matches no operation),
               ~s(infusion.exs pagination: "Nope.list" matches no operation)
             ] == warnings
    end

    test "refuses two operations with one name", %{ir: ir} do
      assert {:error, message} = Config.apply(ir, rename: %{"GET /user" => "Users.get_by_name"})
      assert message =~ "Users.get_by_name would be GET /user and GET /users/{name}"
    end

    test "sets the base URL and auth", %{ir: ir} do
      assert ir.servers == [] and ir.auth == nil
      assert {:ok, ir, []} = Config.apply(ir, base_url: "https://shop.test", auth: :bearer)
      assert [%{url: "https://shop.test"}] = ir.servers
      assert ir.auth == :bearer
    end

    test "pagination: off, overridden, or with the items located", %{ir: ir} do
      list = fn ir -> Enum.find(ir.operations, &(&1.id == "listWebhookEndpoints")) end

      # Two lists in the response: Infusion can't guess which holds the items.
      assert Infusion.Gen.Pagination.detect(list.(ir), ir) == nil

      assert {:error, message} =
               Config.apply(ir, pagination: %{"WebhookEndpoints.list" => [style: :page]})

      assert message =~ ~s(say where it is with items: "data")

      assert {:ok, ir2, []} =
               Config.apply(ir,
                 pagination: %{
                   "WebhookEndpoints.list" => [
                     style: :cursor,
                     param: "page",
                     from: "next",
                     items: "entries"
                   ]
                 }
               )

      assert %{style: :cursor, param: "page", from: ["next"], items: ["entries"], item: item} =
               Infusion.Gen.Pagination.detect(list.(ir2), ir2)

      assert %IR.Schema{kind: :scalar, type: "string"} = item

      # A setting follows a rename, by the new name.
      assert {:ok, ir3, []} =
               Config.apply(ir,
                 rename: %{"listWebhookEndpoints" => "all_endpoints"},
                 pagination: %{"WebhookEndpoints.all_endpoints" => false}
               )

      assert list.(ir3).pagination == false
    end
  end

  describe "Infusion.generate/2 with a config" do
    @tag :tmp_dir
    test "renames, client defaults, and an infusion.exs that loads back", %{tmp_dir: dir} do
      spec = Path.join(dir, "shop.json")
      File.write!(spec, JSON.encode!(@doc_spec))
      out = Path.join(dir, "shop_sdk")

      assert {:ok, result} =
               Infusion.generate(spec,
                 name: Shop,
                 out: out,
                 base_url: "https://shop.test",
                 auth: :bearer,
                 env_var: "SHOP_TOKEN",
                 headers: [{"x-shop-version", "2026-11-01"}],
                 max_retries: 4,
                 rename: %{"GET /user" => "Users.me"},
                 rename_modules: %{"WebhookEndpoints" => "Webhooks"},
                 pagination: %{"Webhooks.list" => [style: :page, items: "entries"]}
               )

      files = Map.new(result.files, &{&1.path, &1.source})

      client = files["lib/shop.ex"]
      assert client =~ ~s(base_url: "https://shop.test")
      assert client =~ ~s(api_key: {:env, "SHOP_TOKEN"})
      assert client =~ "auth: :bearer"
      assert client =~ ~s(headers: [{"x-shop-version", "2026-11-01"}])
      assert client =~ "max_retries: 4"

      assert files["lib/shop/users.ex"] =~ "def me(opts"
      assert files["lib/shop/webhooks.ex"] =~ "def list_all("
      assert Map.has_key?(files, "lib/shop/webhooks/events.ex")
      refute Map.has_key?(files, "lib/shop/webhook_endpoints.ex")

      # Written into the SDK, the config regenerates the same SDK.
      Infusion.write(result.files, out)
      assert {:ok, config} = Config.load(Path.join(out, "infusion.exs"))
      assert config[:spec] == spec
      assert config[:out] == out
      assert config[:name] == "Shop"
      assert config[:app] == :shop_sdk

      {source, config} = Keyword.pop(config, :spec)
      assert {:ok, again} = Infusion.generate(source, config)
      assert Map.new(again.files, &{&1.path, &1.source}) == files
    end

    test "returns config errors" do
      assert {:error, "infusion.exs: :auth must be" <> _} =
               Infusion.generate("unused.json", name: "Shop", auth: :token)
    end
  end
end
