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

  scope "/", UncoverAegisWeb do
    pipe_through :browser

    live "/", InsightsLive
  end
end
