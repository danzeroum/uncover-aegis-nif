defmodule UncoverAegis.QueryCache do
  @moduledoc """
  Cache Redis para resultados de queries NL→SQL.

  ## Estratégia: Cache-Aside (Lazy Loading)

  ```
  get(question)
    → :miss → pipeline completo (LLM → Guardrail → SQLite → Z-Score)
             → put(question, result)
             → retorna result
    → {:hit, result} → retorna direto (sem LLM, sem SQLite)
  ```

  ## Decisões de design

  - **Chave**: SHA256 da pergunta normalizada (lowercase + trim) para
    garantir que "qual o CPA?" e "Qual o CPA?" compartilhem o mesmo cache.
  - **TTL**: 300s (5 min). Dados de campanha são near-real-time;
    um cache maior aumentaria o risco de métricas desatualizadas.
  - **Fallback gracioso**: qualquer erro Redis retorna `:miss` em vez
    de propagar exceção — o pipeline principal nunca é bloqueado por
    indisponibilidade do cache.
  - **SETEX**: operação atômica SET + EXPIRE em comando único, evitando
    race condition entre SET e EXPIRE separados.
  """

  @ttl_seconds 300
  @prefix "aegis:query:"

  @doc """
  Busca resultado em cache.
  Retorna `{:hit, result}` ou `:miss`.
  Falha Redis silenciosa → `:miss`.
  """
  @spec get(String.t()) :: {:hit, map()} | :miss
  def get(question) do
    key = cache_key(question)

    case Redix.command(:redix, ["GET", key]) do
      {:ok, nil}   -> :miss
      {:ok, json}  -> {:hit, Jason.decode!(json)}
      {:error, _}  -> :miss
    end
  end

  @doc """
  Armazena resultado com TTL. Falha silenciosa se Redis indisponível.
  """
  @spec put(String.t(), map()) :: :ok
  def put(question, result) do
    key   = cache_key(question)
    value = Jason.encode!(result)
    Redix.command(:redix, ["SETEX", key, @ttl_seconds, value])
    :ok
  end

  @doc """
  Invalida cache de uma pergunta específica.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(question) do
    Redix.command(:redix, ["DEL", cache_key(question)])
    :ok
  end

  @doc """
  Retorna estatísticas do cache para o painel de Observabilidade.
  """
  @spec stats() :: map()
  def stats do
    case Redix.command(:redix, ["KEYS", "#{@prefix}*"]) do
      {:ok, keys} -> %{cached_queries: length(keys)}
      {:error, _} -> %{cached_queries: :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

  defp cache_key(question) do
    hash =
      :crypto.hash(:sha256, String.downcase(String.trim(question)))
      |> Base.encode16(case: :lower)

    "#{@prefix}#{hash}"
  end
end
