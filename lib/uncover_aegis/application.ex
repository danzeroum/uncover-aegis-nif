defmodule UncoverAegis.Application do
  @moduledoc """
  Arvore de Supervisao OTP do Uncover Aegis.

  ## Processos supervisionados (em ordem de inicializacao)

  1. `UncoverAegis.Repo` — pool de conexoes Ecto com o banco SQLite.
  2. `UncoverAegis.Sentinel.DynamicSupervisor` — supervisor dinamico
     que gerencia um CampaignMonitor (GenServer) por campanha ativa.
  3. `Phoenix.PubSub` — barramento de mensagens que conecta o MVP3
     ao LiveView em tempo real.
  4. `UncoverAegisWeb.Endpoint` — servidor HTTP/WebSocket via Bandit.

  ## Estrategia: :one_for_one

  Falhas sao isoladas: crash num modulo nao reinicia os outros.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # 1. Repositorio Ecto: pool de conexoes SQLite (MVP 2)
      UncoverAegis.Repo,

      # 2. Supervisor dinamico do Sentinel: 1 GenServer por campanha (MVP 3)
      UncoverAegis.Sentinel.DynamicSupervisor,

      # 3. Barramento de eventos: conecta MVP3 -> LiveView (MVP 4)
      {Phoenix.PubSub, name: UncoverAegis.PubSub},

      # 4. Servidor web Phoenix (MVP 4)
      UncoverAegisWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: UncoverAegis.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
