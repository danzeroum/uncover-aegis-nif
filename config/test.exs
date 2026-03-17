import Config

# Configura o banco de dados em memoria para testes.
# Pool Sandbox garante isolamento entre testes concorrentes:
# cada teste recebe sua propria transacao que e revertida ao final.
config :uncover_aegis, UncoverAegis.Repo,
  database: ":memory:",
  pool: Ecto.Adapters.SQLite3.Sandbox,
  pool_size: 1
