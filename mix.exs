defmodule Infusion.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/mandar1045/infusion"

  def project do
    [
      app: :infusion,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Generate official-quality Elixir SDKs from OpenAPI specs",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.11"},
      {:plug, "~> 1.14", only: :test},
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
    [main: "readme", extras: ["README.md", "docs/design.md", "docs/spec-survey.md"]]
  end
end
