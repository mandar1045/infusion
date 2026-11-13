defmodule Infusion.Runtime.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/mandar1045/infusion"

  def project do
    [
      app: :infusion_runtime,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "The runtime shared by SDKs generated with Infusion: HTTP, retries, streaming, pagination",
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.14", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
