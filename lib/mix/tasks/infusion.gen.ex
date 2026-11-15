defmodule Mix.Tasks.Infusion.Gen do
  @shortdoc "Generates an Elixir SDK from an OpenAPI spec"

  @moduledoc """
  Generates an Elixir SDK, as a Mix project, from an OpenAPI 3.0 or 3.1 spec.

      $ mix infusion.gen https://example.com/openapi.yaml --name Example
      $ mix infusion.gen openapi.json --name GitHub --out github_sdk --app github_sdk
      $ mix infusion.gen --config infusion.exs

  The SDK gets an `infusion.exs` with the settings it was generated with, so
  `mix infusion.gen --config github_sdk/infusion.exs` regenerates it in place.
  Renames, auth, headers and pagination overrides go in that file: see
  `Infusion.Config`. With no arguments, `./infusion.exs` is used if there is one.

  Options (they win over the config file):

    * `--config`: an `infusion.exs` file
    * `--name` (required, here or in the config): the base module, e.g. `OpenAI`
    * `--out`: the directory to write to (default: `<name>_sdk`)
    * `--app`: the OTP app name (default: `<name>_sdk`)
    * `--version`: the SDK's version (default: `0.1.0`)
    * `--license`: the SDK's license, for Hex (default: `Apache-2.0`)
    * `--env-var`: where the API key is read from (default: `<NAME>_API_KEY`)
    * `--runtime-path`: depend on a local `infusion_runtime` checkout
  """

  use Mix.Task

  @switches [
    config: :string,
    name: :string,
    out: :string,
    app: :string,
    version: :string,
    license: :string,
    env_var: :string,
    runtime_path: :string
  ]

  @impl true
  def run(args) do
    {opts, sources, _} = OptionParser.parse(args, strict: @switches)

    config_path =
      opts[:config] || if(sources == [] and File.regular?("infusion.exs"), do: "infusion.exs")

    config =
      case config_path && Infusion.Config.load(config_path) do
        nil -> []
        {:ok, config} -> config
        {:error, message} -> Mix.raise(message)
      end

    source =
      case {sources, config[:spec]} do
        {[source], _} ->
          source

        {[], spec} when is_binary(spec) ->
          spec

        _ ->
          Mix.raise(
            "Usage: mix infusion.gen SPEC --name Module, or mix infusion.gen --config infusion.exs"
          )
      end

    name =
      opts[:name] || (config[:name] && to_string(inspect_name(config[:name]))) ||
        Mix.raise("--name is required, e.g. --name OpenAI")

    snake = Infusion.Naming.package(name)
    out = opts[:out] || config[:out] || snake <> "_sdk"
    Application.ensure_all_started(:req)

    gen_opts =
      config
      |> Keyword.drop([:spec])
      |> Keyword.merge(name: name, out: out)
      |> put(:app, opts[:app] && String.to_atom(opts[:app]))
      |> put(:version, opts[:version])
      |> put(:license, opts[:license])
      |> put(:env_var, opts[:env_var])
      |> put(
        :runtime_dep,
        opts[:runtime_path] &&
          "{:infusion_runtime, path: #{inspect(Path.expand(opts[:runtime_path]))}}"
      )

    {micros, result} = :timer.tc(fn -> Infusion.generate(source, gen_opts) end)

    case result do
      {:ok, %{files: files, warnings: warnings, ir: ir}} ->
        # The config this run read is the SDK's own: keep it as written.
        files =
          Enum.reject(files, fn f ->
            f.path == "infusion.exs" and config_path != nil and
              Path.expand(config_path) == Path.expand(Path.join(out, "infusion.exs"))
          end)

        # Files the SDK's author has made their own (`keep:`).
        kept = config[:keep] || []

        files =
          Enum.reject(files, fn f ->
            f.path in kept and File.exists?(Path.join(out, f.path))
          end)

        Infusion.write(files, out)

        Mix.shell().info(
          "Generated #{name} in #{out}/: #{length(ir.operations)} operations, " <>
            "#{map_size(ir.schemas)} schemas, #{length(files)} files " <>
            "(#{div(micros, 1000)} ms)"
        )

        warnings_path = Path.join(out, "infusion_warnings.txt")

        if warnings != [] do
          File.write!(warnings_path, Enum.map_join(warnings, "\n", &warning/1) <> "\n")

          for w <- warnings, is_binary(w), String.starts_with?(w, "infusion.exs") do
            Mix.shell().info([:yellow, "warning: ", :reset, w])
          end

          Mix.shell().info("#{length(warnings)} warnings, see #{warnings_path}")
        else
          File.rm(warnings_path)
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp inspect_name(name) when is_atom(name), do: inspect(name)
  defp inspect_name(name), do: name

  defp warning(%{path: path, message: message}), do: "#{path}: #{message}"
  defp warning(message), do: to_string(message)

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end
