defmodule UncoverAegis.Insights.OllamaClient do
  @moduledoc """
  Cliente HTTP para o Ollama rodando localmente.

  Converte perguntas em linguagem natural para SQL usando o modelo
  `qwen2.5-coder:7b`, que e especializado em geracao de codigo.

  ## System Prompt

  O prompt e deliberadamente restritivo:
  - Responde APENAS com a query SQL, sem markdown, sem explicacao
  - Instrui o modelo a gerar somente SELECT (nunca DML/DDL)
  - Inclui o schema completo da tabela para grounding

  Mesmo que o modelo desobedeça e gere um DELETE/DROP, o Guardrail
  Rust bloqueia antes de tocar o banco — essa e a defesa em profundidade.

  ## Timeout

  `qwen2.5-coder:7b` responde em ~1-3s na VPS. Timeout de 15s para
  cobrir casos de cold start (primeiro request apos idle).
  """

  require Logger

  @ollama_url "http://localhost:11434/api/generate"
  @model "qwen2.5-coder:7b"
  @timeout_ms 15_000

  @system_prompt """
  You are a SQL expert for a marketing analytics platform.
  Your ONLY job is to convert natural language questions into SQL SELECT queries.

  DATABASE SCHEMA:
  Table: campaign_metrics
  Columns:
    - id INTEGER PRIMARY KEY
    - campaign_id TEXT NOT NULL       -- e.g. "camp_google_brand"
    - platform TEXT NOT NULL          -- "google", "meta", "tiktok", "linkedin"
    - spend REAL NOT NULL             -- ad spend in BRL (R$)
    - impressions INTEGER NOT NULL    -- total impressions
    - clicks INTEGER NOT NULL         -- total clicks
    - conversions INTEGER NOT NULL    -- total conversions
    - date DATE NOT NULL              -- date of the record
    - inserted_at DATETIME
    - updated_at DATETIME

  STRICT RULES:
  1. Respond with ONLY the SQL query. No explanation, no markdown, no code blocks.
  2. ONLY generate SELECT queries. Never INSERT, UPDATE, DELETE, DROP, CREATE, or ALTER.
  3. If you cannot answer with a SELECT, respond with exactly: CANNOT_ANSWER
  4. Use standard SQLite syntax.
  5. Always use meaningful column aliases (AS) for aggregations.
  """

  @doc """
  Gera SQL a partir de uma pergunta em linguagem natural via Ollama.

  Retorna `{:ok, sql}` em caso de sucesso, ou erros tipados:
  - `{:error, :cannot_answer}` - modelo nao conseguiu gerar SQL
  - `{:error, :timeout}` - Ollama demorou mais que @timeout_ms
  - `{:error, :unavailable}` - Ollama nao esta rodando
  """
  @spec generate_sql(String.t()) ::
          {:ok, String.t()}
          | {:error, :cannot_answer}
          | {:error, :timeout}
          | {:error, :unavailable}
          | {:error, :not_understood}
  def generate_sql(question) when is_binary(question) do
    body =
      Jason.encode!(%{
        model: @model,
        prompt: question,
        system: @system_prompt,
        stream: false,
        options: %{
          temperature: 0.1,
          top_p: 0.9,
          num_predict: 256
        }
      })

    case http_post(@ollama_url, body) do
      {:ok, %{"response" => response}} ->
        parse_response(response)

      {:error, reason} ->
        Logger.warning("[OllamaClient] Falha: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

  defp http_post(url, body) do
    :application.ensure_started(:inets)
    :application.ensure_started(:ssl)

    headers = [{~c"content-type", ~c"application/json"}]
    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, @timeout_ms}], []) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        Jason.decode(List.to_string(resp_body))

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_error, status}}

      {:error, {:timeout, _}} ->
        {:error, :timeout}

      {:error, {:failed_connect, _}} ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(raw) do
    sql =
      raw
      |> String.trim()
      # Remove blocos de markdown caso o modelo desobedeça
      |> String.replace(~r/```sql\s*/i, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    cond do
      sql == "CANNOT_ANSWER" or sql == "" ->
        {:error, :cannot_answer}

      # Rejeita qualquer tentativa de DML/DDL mesmo se o modelo gerar
      # (o Guardrail Rust e a segunda linha de defesa, mas rejeitamos aqui tambem)
      String.match?(sql, ~r/^\s*(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE)/i) ->
        Logger.warning("[OllamaClient] Modelo gerou DML — rejeitado antes do guardrail: #{sql}")
        {:error, :cannot_answer}

      true ->
        {:ok, sql}
    end
  end
end
