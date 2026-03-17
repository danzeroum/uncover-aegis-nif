defmodule UncoverAegis.Repo do
  @moduledoc """
  Repositorio Ecto do Uncover Aegis.

  Usa o adapter SQLite3 para demonstracao leve:
  - Em dev/prod: arquivo `priv/uncover_aegis_dev.db`
  - Em test: banco em memoria (`:memory:`) com Sandbox para isolamento

  Para producao real, substitua pelo adapter Postgrex (PostgreSQL).
  A interface do Ecto permanece identica.
  """

  use Ecto.Repo,
    otp_app: :uncover_aegis,
    adapter: Ecto.Adapters.SQLite3
end
