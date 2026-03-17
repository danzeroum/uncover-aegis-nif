defmodule UncoverAegisWeb.Layouts do
  @moduledoc """
  Layouts HTML do Uncover Aegis.

  Estrategia CDN-first: Tailwind CSS e Phoenix LiveView JS sao carregados
  via CDN. Elimina a necessidade de pipeline de assets (esbuild/Node.js),
  permitindo que o projeto compile e rode sem dependencias de build extras.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="pt-BR" class="h-full bg-gray-50">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <%!-- csrf token via Plug.CSRFProtection (padrao Phoenix 1.7+) --%>
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Uncover Aegis | Trust OS</title>
        <%!-- Tailwind via CDN: zero pipeline de assets --%%>
        <script src="https://cdn.tailwindcss.com"></script>
        <%!-- Phoenix e LiveView via CDN --%%>
        <script defer src="https://cdn.jsdelivr.net/npm/phoenix@1.7.21/priv/static/phoenix.min.js">
        </script>
        <script defer src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.17/priv/static/phoenix_live_view.min.js">
        </script>
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: { _csrf_token: csrfToken }
            });
            liveSocket.connect();
          });
        </script>
      </head>
      <body class="h-full antialiased font-sans">
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <main class="mx-auto max-w-4xl px-4 py-8 h-screen flex flex-col">
      <%= @inner_content %>
    </main>
    """
  end
end
