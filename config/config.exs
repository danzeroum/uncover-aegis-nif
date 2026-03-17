import Config

# --- Rustler / NIF ---
# Configura a crate Rust compilada pelo Rustler.
# Em :prod usa :release para otimizacoes maximas (LTO, opt-level 3).
# Em :dev/:test usa :debug para compilacao mais rapida.
config :uncover_aegis, UncoverAegis.Native,
  crate: :aegis_core,
  mode: if(Mix.env() == :prod, do: :release, else: :debug)

# --- Ecto / SQLite ---
# Banco SQLite em arquivo fisico (dev/prod).
# Para demonstracao, pode ser trocado por ":memory:" abaixo.
config :uncover_aegis, UncoverAegis.Repo,
  database: "priv/uncover_aegis_dev.db",
  show_sensitive_data_on_connection_error: true,
  pool_size: 5

config :uncover_aegis, ecto_repos: [UncoverAegis.Repo]

import_config "#{config_env()}.exs"
