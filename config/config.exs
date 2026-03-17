import Config

# --- Rustler / NIF ---
config :uncover_aegis, UncoverAegis.Native,
  crate: :aegis_core,
  mode: if(Mix.env() == :prod, do: :release, else: :debug)

# --- Ecto / SQLite ---
config :uncover_aegis, UncoverAegis.Repo,
  database: "priv/uncover_aegis_dev.db",
  show_sensitive_data_on_connection_error: true,
  pool_size: 5

config :uncover_aegis, ecto_repos: [UncoverAegis.Repo]

# --- MVP 4: Phoenix Endpoint (Bandit, sem pipeline de assets) ---
# CDN-first: Tailwind e Phoenix JS carregados via CDN no layout.
# secret_key_base de 64+ chars (obrigatorio pelo Phoenix).
config :uncover_aegis, UncoverAegisWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: UncoverAegisWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: UncoverAegis.PubSub,
  live_view: [signing_salt: "aegis_lv_salt_12345"],
  secret_key_base:
    "Hq3mEp8VnLr2TsKjYwXoZcBfDuGaIyNvOdAkCpMtQlRhJeUbWiSgFxPzEoNaYqT"

import_config "#{config_env()}.exs"
