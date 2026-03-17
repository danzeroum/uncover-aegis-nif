defmodule UncoverAegisWeb.ErrorHTML do
  @moduledoc "Paginas de erro minimas para o Phoenix."

  use Phoenix.Component

  def render("404.html", assigns) do
    ~H"""
    <div class="flex items-center justify-center h-screen">
      <div class="text-center">
        <h1 class="text-4xl font-bold text-gray-800">404</h1>
        <p class="text-gray-600 mt-2">Pagina nao encontrada.</p>
        <a href="/" class="mt-4 inline-block text-blue-600 hover:underline">Voltar ao Aegis</a>
      </div>
    </div>
    """
  end

  def render("500.html", assigns) do
    ~H"""
    <div class="flex items-center justify-center h-screen">
      <div class="text-center">
        <h1 class="text-4xl font-bold text-red-800">500</h1>
        <p class="text-gray-600 mt-2">Erro interno. O Aegis esta investigando.</p>
        <a href="/" class="mt-4 inline-block text-blue-600 hover:underline">Voltar ao Aegis</a>
      </div>
    </div>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
