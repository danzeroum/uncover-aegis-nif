import Config

# SQLite3 nao tem Sandbox como o Postgres.
# Usamos banco em arquivo temporario com pool_size: 1 para serializar os testes.
# O setup de cada teste apaga os dados via DELETE para garantir isolamento.
config :uncover_aegis, UncoverAegis.Repo,
  database: "/tmp/uncover_aegis_test.db",
  pool_size: 1,
  journal_mode: :wal,
  cache_size: -64_000,
  temp_store: :memory

config :logger, level: :warning
