defmodule Infusion.Runtime.SchemaTest do
  use ExUnit.Case, async: true
  alias Infusion.Runtime.Schema

  # Hand-written stand-ins for generated modules.
  defmodule Circle do
    defstruct [:kind, :radius, __extra__: %{}, __present__: []]

    def __schema__(:fields),
      do: [{:kind, "kind", {:const, "circle"}}, {:radius, "radius", :number}]
  end

  defmodule Square do
    defstruct [:kind, :side, __extra__: %{}, __present__: []]
    def __schema__(:fields), do: [{:kind, "kind", {:const, "square"}}, {:side, "side", :number}]
  end

  defmodule Drawing do
    defstruct [:title, :shapes, :tags, :status, :owner_id, __extra__: %{}, __present__: []]

    def __schema__(:fields) do
      [
        {:title, "title", :string},
        {:shapes, "shapes", {:array, {:union, [{:ref, Circle}, {:ref, Square}], nil}}},
        {:tags, "tags", {:map, :string}},
        {:status, "status", {:enum, ["draft", "final"]}},
        {:owner_id, "ownerId", {:union, [:string, {:ref, Circle}], nil}}
      ]
    end
  end

  defmodule Shape do
    def __schema__(:type),
      do:
        {:union, [{:ref, Circle}, {:ref, Square}],
         {"kind", %{"circle" => Circle, "square" => Square}}}
  end

  test "objects: known fields decoded, unknown kept, presence recorded" do
    json = %{
      "title" => "t",
      "status" => "archived",
      "brandNew" => 1,
      "tags" => %{"a" => "b"},
      "ownerId" => nil
    }

    drawing = Schema.decode_module(json, Drawing)

    assert %Drawing{title: "t", tags: %{"a" => "b"}, owner_id: nil} = drawing
    # An enum value the SDK doesn't know stays a string.
    assert drawing.status == "archived"
    assert drawing.__extra__ == %{"brandNew" => 1}
    # null and missing are told apart: owner_id was present (null), shapes missing.
    assert :owner_id in drawing.__present__
    refute :shapes in drawing.__present__
  end

  test "unions without a discriminator: by shape, consts rule variants out" do
    json = %{
      "shapes" => [%{"kind" => "square", "side" => 2}, %{"kind" => "circle", "radius" => 1}],
      "ownerId" => "u_1"
    }

    drawing = Schema.decode_module(json, Drawing)

    assert [%Square{side: 2}, %Circle{radius: 1}] = drawing.shapes
    assert drawing.owner_id == "u_1"
  end

  test "unions with a discriminator, and a tag the SDK doesn't know" do
    assert %Circle{radius: 3} = Schema.decode_module(%{"kind" => "circle", "radius" => 3}, Shape)
    assert %{"kind" => "triangle"} = Schema.decode_module(%{"kind" => "triangle"}, Shape)
  end

  test "nil and wrong-typed data never crash" do
    assert Schema.decode(nil, {:ref, Drawing}) == nil
    assert Schema.decode("x", {:array, :string}) == "x"
    assert %Drawing{shapes: nil} = Schema.decode_module(%{"shapes" => nil}, Drawing)
  end

  test "a schema module that isn't loaded yet is loaded, not mistaken for a non-struct" do
    dir = Path.join(System.tmp_dir!(), "infusion_lazy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Code.delete_path(dir) && File.rm_rf!(dir) end)

    [{module, binary}] =
      Code.compile_string("""
      defmodule Infusion.Runtime.SchemaTest.Lazy do
        defstruct [:id, __extra__: %{}, __present__: []]
        def __schema__(:fields), do: [{:id, "id", :string}]
      end
      """)

    File.write!(Path.join(dir, "#{module}.beam"), binary)
    Code.prepend_path(dir)
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    refute :code.is_loaded(module)

    assert %{__struct__: ^module, id: "x"} = Schema.decode(%{"id" => "x"}, {:ref, module})
  end
end
