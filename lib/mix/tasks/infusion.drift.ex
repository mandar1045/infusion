defmodule Mix.Tasks.Infusion.Drift do
  @shortdoc "Fixes an SDK's spec from what the real API returned"

  @moduledoc """
  Reads a drift report (see `Infusion.Runtime.Drift`) and shows where the
  vendor's spec disagrees with the API, traced to the exact place in the
  spec, with the patch that fixes each one.

      $ mix infusion.drift drift.json
      $ mix infusion.drift drift.json --write
      $ mix infusion.drift drift.json --issue spec-issue.md

  Run it in the SDK's project (next to its `infusion.exs`), with the report
  an app using the SDK exported:

      # in the app, with `config :infusion_runtime, drift: true`
      Infusion.Runtime.Drift.export("drift.json")

  Options:

    * `--config`: the SDK's `infusion.exs` (default: `./infusion.exs`)
    * `--write`: add the patches to `infusion.patches.json` next to it,
      which the next `mix infusion.gen` applies: the SDK gets the fields,
      nulls and enum values the API really returns
    * `--issue FILE`: write a Markdown issue for the API's owners

  Findings that an existing patch already covers are left out: a report
  from an older version of the SDK can be fed again safely.
  """

  use Mix.Task

  @switches [config: :string, write: :boolean, issue: :string]

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: @switches)

    report =
      case files do
        [file] -> file
        _ -> Mix.raise("Usage: mix infusion.drift REPORT.json [--write] [--issue FILE]")
      end

    config_path = opts[:config] || "infusion.exs"

    config =
      case Infusion.Config.load(config_path) do
        {:ok, config} -> config
        {:error, message} -> Mix.raise(message)
      end

    findings = read_report(report)
    spec = config[:spec] || Mix.raise("#{config_path} has no spec")

    built =
      case Infusion.build(spec, config) do
        {:ok, built} -> built
        {:error, message} -> Mix.raise(message)
      end

    entries = Infusion.Drift.analyze(findings, built)
    {covered, entries} = Enum.split_with(entries, &covered?(&1, built.spec))

    print(entries, covered)

    if opts[:write], do: write(entries, config, config_path)

    if path = opts[:issue] do
      File.write!(path, Infusion.Drift.issue(entries, built.base))
      Mix.shell().info("Wrote #{path}")
    end
  end

  defp read_report(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"infusion_drift" => 1, "findings" => findings}} <- Jason.decode(text) do
      findings
    else
      {:error, reason} when is_atom(reason) -> Mix.raise("#{path}: #{:file.format_error(reason)}")
      _ -> Mix.raise("#{path} is not a drift report (Infusion.Runtime.Drift.export/1 writes one)")
    end
  end

  # A finding whose fix is already in the patched spec: e.g. a nullable patch
  # whose property is already nullable.
  defp covered?(%{fixed?: true}, _spec), do: true
  defp covered?(%{patches: []}, _spec), do: false

  defp covered?(%{patches: patches}, spec) do
    {_, warnings} = Infusion.Patch.apply(spec, patches)
    length(warnings) == length(patches)
  end

  defp print([], []), do: Mix.shell().info("No findings in the report.")

  defp print(entries, covered) do
    count = length(entries)
    noun = if count == 1, do: "disagreement", else: "disagreements"
    Mix.shell().info("#{count} #{noun} between the spec and the API:\n")

    for %{finding: f, pointer: pointer, patches: patches, note: note} <- entries do
      where = if f["schema"], do: "#{f["schema"]}.#{f["path"]}", else: f["path"]

      Mix.shell().info([
        :yellow,
        f["kind"],
        :reset,
        " #{where} (#{f["count"]}x)\n",
        "    spec: #{pointer || "?"}\n",
        if(patches == [],
          do: "    #{note || "no patch"}\n",
          else: Enum.map(patches, &"    fix:  #{&1["op"]} #{inspect(&1["value"])}\n")
        )
      ])
    end

    if covered != [],
      do: Mix.shell().info("#{length(covered)} more already fixed by infusion.patches.json.")
  end

  defp write(entries, config, config_path) do
    path =
      case config[:patches] do
        file when is_binary(file) -> file
        nil -> Path.join(Path.dirname(Path.expand(config_path)), "infusion.patches.json")
        _list -> Mix.raise("infusion.exs lists patches inline: copy them there by hand")
      end

    existing =
      case File.read(path) do
        {:ok, text} -> Jason.decode!(text)
        {:error, :enoent} -> []
      end

    new = Enum.flat_map(entries, & &1.patches)
    patches = Infusion.Drift.merge_patches(existing, new)

    File.write!(
      path,
      Jason.encode_to_iodata!(patches, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n")
    )

    Mix.shell().info(
      "\nWrote #{length(new)} patches to #{Path.relative_to_cwd(path)}. " <>
        "Regenerate with `mix infusion.gen` to apply them."
    )
  end
end
