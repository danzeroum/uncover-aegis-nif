defmodule UncoverAegisWeb.ConnCase do
  @moduledoc """
  Modulo de suporte para testes de controllers Phoenix.

  Fornece um `conn` configurado com os headers padrao para cada teste.
  Importa helpers do Phoenix.ConnTest para facilitar chamadas HTTP nos testes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      alias UncoverAegisWeb.Router.Helpers, as: Routes

      @endpoint UncoverAegisWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
