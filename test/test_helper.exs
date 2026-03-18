ExUnit.start()

# Garante que as migrations foram aplicadas no banco de testes
{:ok, _} = Application.ensure_all_started(:uncover_aegis)
Ecto.Migrator.run(UncoverAegis.Repo, :up, all: true, log: false)
