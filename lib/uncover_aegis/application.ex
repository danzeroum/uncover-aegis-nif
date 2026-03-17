defmodule UncoverAegis.Application do
  @moduledoc """
  Árvore de Supervisão OTP do Uncover Aegis.

  Gerencia o ciclo de vida de todos os processos segundo a filosofia
  "Let it crash" do Erlang/OTP: falhas isoladas são reiniciadas
  automaticamente sem derrubar o sistema inteiro.

  ## Processos supervisionados (em ordem de inicialização)

  1. `UncoverAegis.Repo` — pool de conexões Ecto com o banco SQLite.
     Deve ser iniciado primeiro: outros módulos dependem do banco.

  2. `UncoverAegis.Sentinel.DynamicSupervisor` — supervisor dinâmico
     que gerencia um `CampaignMonitor` (GenServer) por campanha ativa.
     Iniciado após o Repo pois monitores futuros podem persistir alertas.

  ## Estratégia: `:one_for_one`

  Se o Repo ou o Sentinel falharem, apenas o processo afetado é reiniciado.
  Não há dependência de restart entre eles.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Repositório Ecto: pool de conexões SQLite (MVP 2)
      UncoverAegis.Repo,

      # 2. Supervisor dinâmico do Sentinel: 1 GenServer por campanha (MVP 3)
      UncoverAegis.Sentinel.DynamicSupervisor
    ]

    opts = [strategy: :one_for_one, name: UncoverAegis.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
