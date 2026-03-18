defmodule UncoverAegis.MixProject do
  use Mix.Project

  def project do
    [
      app: :uncover_aegis,
      version: "0.3.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ],
      description: "Motor unificado de governanca de IA para MarTech: ingestao segura, insights controlados e monitoramento preditivo.",
      source_url: "https://github.com/danzeroum/uncover-aegis-nif"
    ]
  end

  # test/support so e compilado no ambiente :test
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {UncoverAegis.Application, []}
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36.0"},
      {:ecto_sqlite3, "~> 0.18.0"},
      {:ecto_sql, "~> 3.11"},
      {:phoenix, "~> 1.7.11"},
      {:phoenix_live_view, "~> 0.20.14"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
