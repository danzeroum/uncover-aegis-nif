defmodule UncoverAegisWeb do
  @moduledoc """
  Contexto web do Uncover Aegis (MVP 4).

  Centraliza os `use` para LiveView e Router, seguindo o padrao
  Phoenix 1.7 sem o helper legado `Phoenix.LiveView.Helpers`.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {UncoverAegisWeb.Layouts, :app}
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
