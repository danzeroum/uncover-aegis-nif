defmodule UncoverAegis.Application do
  @moduledoc """
  Arvore de Supervisao OTP do Uncover Aegis.

  Gerencia o ciclo de vida de todos os processos segundo a filosofia
  "Let it crash" do Erlang/OTP: falhas isoladas sao reiniciadas
  automaticamente sem derrubar o sistema inteiro.

  ## Processos supervisionados

  1. `UncoverAegis.Repo` — pool de conexoes com o banco de dados SQLite.
     Obrigatorio para que o Ecto funcione. Sem ele, qualquer chamada
     `Repo.query/2` falha com `:noproc`.

  2. (Futuro MVP 3) `UncoverAegis.Sentinel.Supervisor` — DynamicSupervisor
     que iniciara um GenServer por campanha monitorada.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Repositorio Ecto: gerencia o pool de conexoes SQLite
      UncoverAegis.Repo

      # 2. Ponto de extensao para o MVP 3 (Sentinel):
      # {UncoverAegis.Sentinel.Supervisor, []}
    ]

    opts = [strategy: :one_for_one, name: UncoverAegis.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
