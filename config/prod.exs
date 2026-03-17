import Config

# Em producao, usar arquivo de banco externo ou variavel de ambiente.
config :uncover_aegis, UncoverAegis.Repo,
  database: System.get_env("DATABASE_PATH", "priv/uncover_aegis_prod.db")
