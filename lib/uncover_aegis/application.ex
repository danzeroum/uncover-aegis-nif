defmodule UncoverAegis.Application do
  @moduledoc """
  Árvore de Supervisão OTP do Uncover Aegis.

  Gerencia o ciclo de vida dos processos da aplicação segundo a filosofia
  "Let it crash" do Erlang/OTP: falhas isoladas são reiniciadas automaticamente
  sem derrubar o sistema inteiro.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Ponto de extensão: adicione Workers, GenServers, etc.
      # Exemplo futuro:
      # {UncoverAegis.Worker, []}
    ]

    opts = [strategy: :one_for_one, name: UncoverAegis.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
