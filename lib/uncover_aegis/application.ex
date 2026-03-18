defmodule UncoverAegis.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UncoverAegis.Repo,
      {Phoenix.PubSub, name: UncoverAegis.PubSub},
      UncoverAegisWeb.Endpoint,
      UncoverAegis.AnomalyDetector,
      UncoverAegis.TelemetryStore
    ]

    opts = [strategy: :one_for_one, name: UncoverAegis.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
