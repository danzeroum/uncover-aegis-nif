defmodule UncoverAegis.DataCase do
  @moduledoc """
  Template de caso de teste para modulos que interagem com o banco de dados.

  Utiliza o `Ecto.Adapters.SQLite3.Sandbox` para garantir que cada teste
  rode numa transacao isolada que e revertida ao final, sem efeitos colaterais
  entre testes.

  ## Uso

      defmodule MeuModuloTest do
        use UncoverAegis.DataCase, async: true
        # ...
      end

  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias UncoverAegis.Repo

      import Ecto
      import Ecto.Query
      import UncoverAegis.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(UncoverAegis.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
