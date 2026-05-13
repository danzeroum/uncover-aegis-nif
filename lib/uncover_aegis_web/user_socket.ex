defmodule UncoverAegisWeb.UserSocket do
  @moduledoc """
  Socket WebSocket do Uncover Aegis.

  Usado pelo Absinthe para entregar GraphQL Subscriptions em tempo real.
  Quando um cliente abre `ws://host/socket/websocket`, o Phoenix estabelece
  a conexao aqui antes de encaminhar para o canal Absinthe.

  ## Como funciona

  ```
  Cliente GraphQL
    |
    | ws://localhost:4000/socket/websocket
    v
  UncoverAegisWeb.UserSocket   <- este arquivo
    |
    | canal "__absinthe__:control"
    v
  Absinthe.Phoenix.Channel     <- gerencia sub/unsub de subscriptions
    |
    | Phoenix.PubSub.broadcast(
    |   UncoverAegis.PubSub,
    |   "sentinel:campanha_1", %{...}
    | )
    v
  Cliente recebe o evento via WebSocket
  ```
  """

  use Phoenix.Socket

  # Absinthe usa um canal proprio para controlar subscriptions.
  # O padrao "__absinthe__:*" e reservado pela biblioteca.
  channel "__absinthe__:*", Absinthe.Phoenix.Channel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
