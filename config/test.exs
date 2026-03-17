import Config

# Banco em memoria para testes: reseta a cada execucao, sem estado residual.
# O Sandbox garante isolamento entre testes concorrentes (async: true).
config :uncover_aegis, UncoverAegis.Repo,
  database: ":memory:",
  pool: Ecto.Adapters.SQLite3.Sandbox,
  pool_size: 5
