defmodule UncoverAegisWeb.Router do
  use UncoverAegisWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {UncoverAegisWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(UncoverAegisWeb.Plugs.RequestLogger)
  end

  pipeline :graphql do
    plug(:accepts, ["json"])
  end

  # ── Browser / LiveView ────────────────────────────────────────────────

  scope "/", UncoverAegisWeb do
    pipe_through(:browser)
    live("/", InsightsLive)
  end

  # ── REST API ────────────────────────────────────────────────────────────

  scope "/api", UncoverAegisWeb.Api do
    pipe_through(:api)
    get("/health", HealthController, :index)
  end

  scope "/api/v1", UncoverAegisWeb.Api do
    pipe_through(:api)

    # MVP 2 — Text-to-SQL com guardrail Rust
    post("/insights/query", InsightsController, :query)
    get("/campaigns/metrics", MetricsController, :index)

    # MVP 4 — Marketing Mix Modeling
    post("/mmm/adstock", AdstockController, :calculate)
  end

  # ── GraphQL (Absinthe) ────────────────────────────────────────────────────
  # Phoenix 1.7: forward/2 recebe o módulo plug diretamente, sem wrapper init_opts.
  # As opções são passadas como terceiro argumento implicitamente pelo forward/2.

  scope "/api" do
    pipe_through(:graphql)

    # POST /api/graphql — queries, mutations e subscriptions
    forward("/graphql", Absinthe.Plug, schema: UncoverAegisWeb.Schema)
  end

  # GraphiQL Playground (apenas ambiente de desenvolvimento)
  if Mix.env() == :dev do
    forward(
      "/graphiql",
      Absinthe.Plug.GraphiQL,
      schema: UncoverAegisWeb.Schema,
      interface: :playground,
      socket: UncoverAegisWeb.UserSocket
    )
  end
end
