ExUnit.start()

# Garante que as migrations foram aplicadas no banco de testes
Alias = UncoverAegis.Repo
Ecto.Adapters.SQL.Sandbox

# Roda migrations antes da suite de testes
{:ok, _} = Application.ensure_all_started(:uncover_aegis)
Ecto.Migrator.run(UncoverAegis.Repo, :up, all: true, log: false)
