defmodule UncoverAegisWeb.Endpoint do
  @moduledoc """
  Endpoint Phoenix do Uncover Aegis.

  Usa Bandit como servidor HTTP/WebSocket (substituicao moderna
  e mais rapida ao Cowboy). Sem pipeline de assets: Tailwind e
  Phoenix JS sao carregados via CDN no layout.
  """

  use Phoenix.Endpoint, otp_app: :uncover_aegis

  @session_options [
    store: :cookie,
    key: "_uncover_aegis_key",
    signing_salt: "aegis_salt_2025",
    same_site: "Lax"
  ]

  # Socket do LiveView (existente)
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Socket para GraphQL Subscriptions via Absinthe (novo)
  # Caminho: ws://host/socket/websocket
  socket "/socket", UncoverAegisWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.Session, @session_options
  plug UncoverAegisWeb.Router
end
