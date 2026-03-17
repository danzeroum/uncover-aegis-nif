defmodule UncoverAegisWeb.Router do
  use UncoverAegisWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UncoverAegisWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # ---------------------------------------------------------------------------
  # Browser — LiveView
  # ---------------------------------------------------------------------------

  scope "/", UncoverAegisWeb do
    pipe_through :browser

    live "/", InsightsLive
  end

  # ---------------------------------------------------------------------------
  # API REST
  # ---------------------------------------------------------------------------

  scope "/api", UncoverAegisWeb.Api do
    pipe_through :api

    # Health check — usado por load balancers e monitoramento
    get "/health", HealthController, :index
  end

  scope "/api/v1", UncoverAegisWeb.Api do
    pipe_through :api

    # Insights conversacional (NL -> SQL ou SQL direto)
    post "/insights/query", InsightsController, :query

    # Metricas de campanhas com filtros
    get "/campaigns/metrics", MetricsController, :index
  end
end
