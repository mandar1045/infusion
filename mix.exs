defmodule Infusion.MixProject do
  use Mix.Project

  @version "0.6.1"
  @source_url "https://github.com/mandar1045/infusion"

  def project do
    [
      app: :infusion,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Tests compile generated SDK code, whose structs derive Inspect.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description: "Generate official-quality Elixir SDKs from OpenAPI specs",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.11"},
      {:plug, "~> 1.14", only: :test},
      # Generated code is compiled and run in the tests.
      {:infusion_runtime, path: "runtime", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "docs/design.md", "docs/spec-survey.md", "CHANGELOG.md"],
      assets: %{"docs/images" => "docs/images"}
    ]
  end
end
