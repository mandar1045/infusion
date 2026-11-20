defmodule Infusion.Runtime.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Infusion.Runtime.Application, []}]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.14", only: :test},
      {:phoenix_pubsub, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # The runtime lives in runtime/ of the Infusion repository.
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url_pattern: "#{@source_url}/blob/v#{@version}/runtime/%{path}#L%{line}"
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
