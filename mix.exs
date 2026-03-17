defmodule UncoverAegis.MixProject do
  use Mix.Project

  def project do
    [
      app: :uncover_aegis,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Hybrid Elixir+Rust pipeline for PII sanitization in MarTech AI workflows",
      source_url: "https://github.com/danzeroum/uncover-aegis-nif"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {UncoverAegis.Application, []}
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36.0"}
    ]
  end
end
