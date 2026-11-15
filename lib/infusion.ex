defmodule Infusion do
  @moduledoc """
  Generates Elixir SDKs from OpenAPI specs.

      {:ok, result} = Infusion.generate("openapi.yaml", name: "OpenAI")
      result.files     #=> [%{path: "lib/openai/models.ex", source: "..."}, ...]
      result.warnings  #=> what the spec does that the SDK can't represent

  Or from the command line, `mix infusion.gen`. See the
  [design](docs/design.md) for how specs become SDKs.
  """

  alias Infusion.{Config, IR, Normalize, Ref, Spec}
  alias Infusion.Gen.{Operations, Project, Schemas}

  @doc """
  Generates the files of an SDK from `source` (a path or URL).

  Options: `:name` (the base module, required), every key of
  `Infusion.Config` (what an `infusion.exs` file holds: renames, auth,
  pagination, ...), plus those of `Infusion.Gen.Project.render/4` and
  `Infusion.Spec.load/2`.
  """
  @spec generate(String.t(), keyword) ::
          {:ok, %{files: [Schemas.file()], warnings: [String.t()], ir: %IR{}}}
          | {:error, String.t()}
  def generate(source, opts) do
    base = opts |> Keyword.fetch!(:name) |> base_name()
    opts = Keyword.put(opts, :name, base)
    config = Keyword.take(opts, Config.keys())

    with :ok <- Config.validate(config),
         {:ok, spec} <- Spec.load(source, opts),
         {:ok, resolved} <- Ref.resolve(spec.document),
         {:ok, document, normalize_warnings} <- Normalize.run(resolved),
         {:ok, ir} <- IR.build(document),
         {:ok, ir, config_warnings} <- Config.apply(ir, config) do
      {ir, modules} = Schemas.prepare(ir, base, Keyword.take(config, [:schema_names]))
      schema_files = Schemas.render(ir, base, modules)
      operation_files = Operations.render(ir, base, modules)
      project_files = Project.render(ir, base, document, Keyword.put(opts, :spec, source))

      {:ok,
       %{
         files: project_files ++ operation_files ++ schema_files,
         warnings: config_warnings ++ normalize_warnings ++ ir.warnings,
         ir: ir
       }}
    end
  end

  # GitHub (an alias) or "GitHub".
  defp base_name(name) when is_atom(name), do: inspect(name)
  defp base_name(name), do: name

  @doc "Writes generated `files` under `dir`."
  @spec write([Schemas.file()], Path.t()) :: :ok
  def write(files, dir) do
    for %{path: path, source: source} <- files do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, source)
    end

    :ok
  end
end
