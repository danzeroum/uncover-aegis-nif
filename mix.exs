defmodule UncoverAegis.MixProject do
  use Mix.Project

  def project do
    [
      app: :uncover_aegis,
      version: "0.3.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Motor unificado de governanca de IA para MarTech: ingestao segura, insights controlados e monitoramento preditivo.",
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
      # NIF bridge: compila Rust e carrega como biblioteca dinamica na BEAM
      {:rustler, "~> 0.36.0"},

      # Banco de dados SQLite leve para demonstracao e testes
      {:ecto_sqlite3, "~> 0.18.0"},
      {:ecto_sql, "~> 3.11"},

      # --- MVP 4: Web e LiveView ---
      # Phoenix 1.7 + LiveView 0.20 sem pipeline de assets (CDN)
      {:phoenix, "~> 1.7.11"},
      {:phoenix_live_view, "~> 0.20.14"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      # Prepara o ambiente de teste criando e migrando o banco em memoria
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
