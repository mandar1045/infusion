defmodule Mix.Tasks.Infusion.Gen do
  @shortdoc "Generates an Elixir SDK from an OpenAPI spec"

  @moduledoc """
  Generates an Elixir SDK, as a Mix project, from an OpenAPI 3.0 or 3.1 spec.

      $ mix infusion.gen https://example.com/openapi.yaml --name Example
      $ mix infusion.gen openapi.json --name GitHub --out github_sdk --app github_sdk

  Options:

    * `--name` (required): the base module, e.g. `OpenAI`
    * `--out`: the directory to write to (default: `<name>_sdk`)
    * `--app`: the OTP app name (default: `<name>_sdk`)
    * `--version`: the SDK's version (default: `0.1.0`)
    * `--license`: the SDK's license, for Hex (default: `Apache-2.0`)
    * `--env-var`: where the API key is read from (default: `<NAME>_API_KEY`)
    * `--runtime-path`: depend on a local `infusion_runtime` checkout
  """

  use Mix.Task

  @switches [
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

    source =
      case sources do
        [source] -> source
        _ -> Mix.raise("Usage: mix infusion.gen SPEC --name Module")
      end

    name = opts[:name] || Mix.raise("--name is required, e.g. --name OpenAI")
    snake = Infusion.Naming.package(name)
    out = opts[:out] || snake <> "_sdk"
    Application.ensure_all_started(:req)

    gen_opts =
      [name: name]
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
        Infusion.write(files, out)

        Mix.shell().info(
          "Generated #{name} in #{out}/: #{length(ir.operations)} operations, " <>
            "#{map_size(ir.schemas)} schemas, #{length(files)} files " <>
            "(#{div(micros, 1000)} ms)"
        )

        if warnings != [] do
          path = Path.join(out, "infusion_warnings.txt")
          File.write!(path, Enum.map_join(warnings, "\n", &warning/1) <> "\n")
          Mix.shell().info("#{length(warnings)} warnings, see #{path}")
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp warning(%{path: path, message: message}), do: "#{path}: #{message}"
  defp warning(message), do: to_string(message)

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)
end
