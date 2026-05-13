defmodule UncoverAegis.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Repositório Ecto (SQLite3)
      UncoverAegis.Repo,

      # PubSub in-process (para LiveView + GraphQL subscriptions)
      {Phoenix.PubSub, name: UncoverAegis.PubSub},

      # Endpoint Phoenix (REST + LiveView + GraphQL)
      UncoverAegisWeb.Endpoint,

      # Sentinel: DynamicSupervisor gerencia 1 GenServer por campanha
      UncoverAegis.Sentinel.DynamicSupervisor,

      # Observabilidade: ring buffer ETS (500 eventos)
      UncoverAegis.TelemetryStore,

      # Cache Redis para queries NL→SQL
      # Fallback gracioso: se Redis estiver offline, QueryCache retorna :miss
      {Redix, host: redis_host(), port: 6379, name: :redix}
    ]

    opts = [strategy: :one_for_one, name: UncoverAegis.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp redis_host do
    System.get_env("REDIS_HOST", "localhost")
  end
end
