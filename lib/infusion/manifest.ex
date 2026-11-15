defmodule Infusion.Manifest do
  @moduledoc """
  What Infusion wrote into an SDK, so regenerating it can clean up.

  `.infusion/manifest.json` lists every generated file with the SHA-256 of
  what was written:

      {
        "generator": "infusion 0.5.0",
        "files": {
          "lib/twilio/messages.ex": "4f2a...",
          ...
        }
      }

  On the next run (`write/3`), files the new run doesn't generate are deleted
  (a schema that was renamed or removed from the spec), and a generated file
  whose content no longer matches its hash was edited by hand: the run stops
  and names it, rather than overwrite or delete the edit, unless `force: true`.
  Files that aren't in the manifest (hand-written tests, `lib/<sdk>/custom/`)
  are never touched, and a new generated file that would replace one of them
  stops the run the same way.
  """

  @path ".infusion/manifest.json"

  @doc "Where the manifest lives, relative to the SDK."
  def path, do: @path

  @doc "The files and hashes of the last run in `dir`; empty when there is none."
  @spec read(Path.t()) :: %{String.t() => String.t()}
  def read(dir) do
    case File.read(Path.join(dir, @path)) do
      {:ok, json} -> json |> JSON.decode!() |> Map.get("files", %{})
      {:error, _} -> %{}
    end
  end

  @doc """
  Writes `files` into `dir` and updates the manifest. Returns what changed,
  or `{:error, edited}`: the generated files that were edited by hand and
  would be overwritten or deleted.

  Options: `:force` (overwrite and delete hand edits too), `:untracked`
  (paths written but not owned, such as `infusion.exs`: never recorded,
  never deleted).
  """
  @spec write([%{path: String.t(), source: String.t()}], Path.t(), keyword) ::
          {:ok, %{written: non_neg_integer, removed: [String.t()]}}
          | {:error, {:edited, [String.t()]}}
  def write(files, dir, opts \\ []) do
    untracked = MapSet.new(opts[:untracked] || [])
    old = read(dir) |> Map.drop(MapSet.to_list(untracked))

    new =
      for f <- files,
          not MapSet.member?(untracked, f.path),
          into: %{},
          do: {f.path, hash(f.source)}

    stale = old |> Map.keys() |> Enum.reject(&Map.has_key?(new, &1))

    # A file that is still what we wrote is ours to replace; one that changed
    # since was edited by hand.
    edited =
      for {path, written} <- Enum.sort(old),
          content = file(dir, path),
          content != nil and hash(content) != written,
          # Rewriting a file with what is already there loses nothing.
          new[path] != hash(content),
          do: path

    # A file this run would create where a file of the author's already is
    # (a new resource named like their `custom/` module). Only once there is
    # a manifest: in an SDK generated before manifests, every file is like that.
    edited =
      if old == %{} do
        edited
      else
        taken =
          for {path, hash} <- Enum.sort(new),
              not Map.has_key?(old, path),
              content = file(dir, path),
              content != nil and hash(content) != hash,
              do: path

        Enum.sort(edited ++ taken)
      end

    if edited != [] and not Keyword.get(opts, :force, false) do
      {:error, {:edited, edited}}
    else
      Infusion.write(files, dir)

      for path <- stale do
        File.rm(Path.join(dir, path))
        prune(Path.dirname(path), dir)
      end

      write_manifest(dir, new)
      {:ok, %{written: length(files), removed: Enum.sort(stale)}}
    end
  end

  defp file(dir, path) do
    case File.read(Path.join(dir, path)) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  # Removes directories a deletion left empty, up to the SDK's root.
  defp prune(".", _dir), do: :ok

  defp prune(rel, dir) do
    full = Path.join(dir, rel)

    if File.dir?(full) and File.ls!(full) == [] do
      File.rmdir(full)
      prune(Path.dirname(rel), dir)
    end

    :ok
  end

  # One file per line, sorted, so changes to the manifest read well in a diff.
  defp write_manifest(dir, files) do
    entries =
      files
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {path, hash} ->
        "    #{JSON.encode!(path)}: #{JSON.encode!(hash)}"
      end)

    json = """
    {
      "generator": #{JSON.encode!("infusion " <> version())},
      "files": {
    #{entries}
      }
    }
    """

    target = Path.join(dir, @path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, json)
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp version, do: to_string(Application.spec(:infusion, :vsn) || "dev")
end
