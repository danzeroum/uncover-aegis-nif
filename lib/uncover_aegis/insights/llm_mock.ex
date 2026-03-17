defmodule UncoverAegis.Insights.LlmMock do
  @moduledoc """
  Simulador de LLM para o MVP4.

  Mapeia perguntas em linguagem natural para queries SQL seguras.
  Simula o papel de um modelo de linguagem que seria chamado via API
  (ex: OpenAI GPT-4) em producao.

  ## Design

  A abordagem intencional e o mapeamento por pattern matching exato,
  que demonstra o fluxo completo (NL -> SQL -> Guardrail -> Ecto)
  sem depender de uma API externa durante a demonstracao.

  Em producao, substitua este modulo por um cliente HTTP que chama
  a OpenAI com um system prompt que instrua o modelo a gerar apenas
  SELECT queries na schema do `campaign_metrics`.
  """

  @doc """
  Converte uma pergunta em linguagem natural para um SQL.

  Retorna `{:ok, sql}` para perguntas reconhecidas, ou
  `{:error, :not_understood}` para perguntas desconhecidas.
  """
  @spec generate_sql(String.t()) :: {:ok, String.t()} | {:error, :not_understood}
  def generate_sql(question) when is_binary(question) do
    case normalize(question) do
      q when q in ["qual o gasto total", "gasto total", "total de gasto"] ->
        {:ok, "SELECT platform, SUM(spend) AS total_spend FROM campaign_metrics GROUP BY platform ORDER BY total_spend DESC"}

      q when q in ["quais campanhas tiveram mais cliques", "campanhas com mais cliques", "top campanhas por cliques"] ->
        {:ok, "SELECT campaign_id, SUM(clicks) AS total_clicks FROM campaign_metrics GROUP BY campaign_id ORDER BY total_clicks DESC LIMIT 5"}

      q when q in ["qual a taxa de conversao", "taxa de conversao", "conversao media"] ->
        {:ok, "SELECT platform, AVG(CAST(conversions AS FLOAT) / NULLIF(clicks, 0)) AS conversion_rate FROM campaign_metrics GROUP BY platform ORDER BY conversion_rate DESC"}

      q when q in ["quais plataformas usamos", "plataformas ativas", "que plataformas temos"] ->
        {:ok, "SELECT DISTINCT platform FROM campaign_metrics ORDER BY platform"}

      q when q in ["qual o custo por clique", "cpc medio", "custo por clique"] ->
        {:ok, "SELECT platform, AVG(spend / NULLIF(clicks, 0)) AS avg_cpc FROM campaign_metrics GROUP BY platform ORDER BY avg_cpc"}

      q when q in ["quantas campanhas temos", "numero de campanhas", "total campanhas"] ->
        {:ok, "SELECT COUNT(DISTINCT campaign_id) AS total_campaigns FROM campaign_metrics"}

      _ ->
        {:error, :not_understood}
    end
  end

  # Normaliza a pergunta: lowercase, remove pontuacao e espacos extras
  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[?!.,;:]/, "")
    |> String.trim()
  end
end
