defmodule Infusion.ManifestTest do
  use ExUnit.Case, async: true

  alias Infusion.Manifest

  defp files(map), do: Enum.map(map, fn {path, source} -> %{path: path, source: source} end)

  @tag :tmp_dir
  test "regenerating replaces what it wrote and removes what it no longer writes", %{tmp_dir: dir} do
    assert {:ok, %{removed: []}} =
             Manifest.write(
               files(%{"lib/a.ex" => "a1", "lib/old/b.ex" => "b1", "infusion.exs" => "[]"}),
               dir,
               untracked: ["infusion.exs"]
             )

    assert Map.keys(Manifest.read(dir)) == ["lib/a.ex", "lib/old/b.ex"]

    # Hand-written files are not the generator's.
    File.write!(Path.join(dir, "lib/custom.ex"), "mine")

    assert {:ok, %{removed: ["lib/old/b.ex"]}} =
             Manifest.write(files(%{"lib/a.ex" => "a2", "lib/c.ex" => "c1"}), dir,
               untracked: ["infusion.exs"]
             )

    assert File.read!(Path.join(dir, "lib/a.ex")) == "a2"
    refute File.exists?(Path.join(dir, "lib/old"))
    assert File.read!(Path.join(dir, "lib/custom.ex")) == "mine"
    assert File.read!(Path.join(dir, "infusion.exs")) == "[]"
    assert Map.keys(Manifest.read(dir)) == ["lib/a.ex", "lib/c.ex"]
  end

  @tag :tmp_dir
  test "a generated file edited by hand stops the run, unless forced", %{tmp_dir: dir} do
    {:ok, _} = Manifest.write(files(%{"lib/a.ex" => "a1", "lib/b.ex" => "b1"}), dir)
    File.write!(Path.join(dir, "lib/a.ex"), "a1 plus a fix")
    File.write!(Path.join(dir, "lib/b.ex"), "b1 plus a fix")

    # a would be overwritten, b deleted: both are reported, nothing is written.
    assert {:error, {:edited, ["lib/a.ex", "lib/b.ex"]}} =
             Manifest.write(files(%{"lib/a.ex" => "a2"}), dir)

    assert File.read!(Path.join(dir, "lib/a.ex")) == "a1 plus a fix"

    # Regenerating exactly what is there loses nothing, so it isn't an edit.
    File.write!(Path.join(dir, "lib/b.ex"), "b1")
    File.write!(Path.join(dir, "lib/a.ex"), "a2")
    assert {:ok, %{removed: ["lib/b.ex"]}} = Manifest.write(files(%{"lib/a.ex" => "a2"}), dir)

    File.write!(Path.join(dir, "lib/a.ex"), "edited")

    assert {:ok, _} = Manifest.write(files(%{"lib/a.ex" => "a3"}), dir, force: true)
    assert File.read!(Path.join(dir, "lib/a.ex")) == "a3"
  end

  @tag :tmp_dir
  test "the first run in an existing SDK deletes nothing", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/stale.ex"), "from before manifests")

    assert {:ok, %{removed: []}} = Manifest.write(files(%{"lib/a.ex" => "a"}), dir)
    assert File.exists?(Path.join(dir, "lib/stale.ex"))

    json = File.read!(Path.join(dir, ".infusion/manifest.json"))
    assert %{"generator" => "infusion " <> _, "files" => %{"lib/a.ex" => _}} = JSON.decode!(json)
  end

  @tag :tmp_dir
  test "a new generated file never replaces one of the author's", %{tmp_dir: dir} do
    {:ok, _} = Manifest.write(files(%{"lib/a.ex" => "a"}), dir)
    File.mkdir_p!(Path.join(dir, "lib/custom"))
    File.write!(Path.join(dir, "lib/custom/webhook.ex"), "mine")

    assert {:error, {:edited, ["lib/custom/webhook.ex"]}} =
             Manifest.write(
               files(%{"lib/a.ex" => "a", "lib/custom/webhook.ex" => "generated"}),
               dir
             )

    assert File.read!(Path.join(dir, "lib/custom/webhook.ex")) == "mine"
  end
end
