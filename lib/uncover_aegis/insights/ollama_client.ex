defmodule UncoverAegis.Insights.OllamaClient do
  @moduledoc """
  Cliente HTTP para o Ollama rodando localmente.
  Usa :gen_tcp com HTTP/1.0 para evitar chunked transfer encoding.
  Timeout de 60s para cobrir cold start do qwen2.5-coder:7b.
  """

  require Logger

  @ollama_host ~c"localhost"
  @ollama_port 11434
  @ollama_path "/api/generate"
  @model "qwen2.5-coder:7b"
  @connect_timeout 5_000
  @recv_timeout 60_000

  defp system_prompt do
    today = Date.utc_today() |> Date.to_iso8601()

    """
    You are a SQL expert for a marketing analytics platform.
    Your ONLY job is to convert natural language questions into SQL SELECT queries.

    TODAY'S DATE: #{today}
    When the user mentions relative dates ("today", "yesterday", "this month") or partial
    dates ("March 13", "dia 13 de marco"), always resolve them using #{today} as reference.
    Always use the full ISO 8601 format (YYYY-MM-DD) in WHERE clauses.

    DATABASE SCHEMA:
    Table: campaign_metrics
    Columns:
      - id INTEGER PRIMARY KEY
      - campaign_id TEXT NOT NULL
      - platform TEXT NOT NULL          -- "google", "meta", "tiktok", "linkedin"
      - spend REAL NOT NULL             -- ad spend in BRL (R$)
      - impressions INTEGER NOT NULL
      - clicks INTEGER NOT NULL
      - conversions INTEGER NOT NULL
      - date DATE NOT NULL              -- format: YYYY-MM-DD

    KEY MARKETING METRICS (use these formulas when relevant):
      - CPC (Cost per Click):       ROUND(SUM(spend) / NULLIF(SUM(clicks), 0), 2)
      - CPA (Cost per Acquisition): ROUND(SUM(spend) / NULLIF(SUM(conversions), 0), 2)
      - CVR (Conversion Rate):      ROUND(CAST(SUM(conversions) AS REAL) / NULLIF(SUM(clicks), 0), 4)
      - CTR (Click-Through Rate):   ROUND(CAST(SUM(clicks) AS REAL) / NULLIF(SUM(impressions), 0), 4)

    STRICT RULES:
    1. Respond with ONLY the SQL query. No explanation, no markdown, no code blocks.
    2. ONLY generate SELECT queries. Never INSERT, UPDATE, DELETE, DROP, CREATE, or ALTER.
    3. If you cannot answer with a SELECT, respond with exactly: CANNOT_ANSWER
    4. Use standard SQLite syntax.
    5. Always use meaningful column aliases (AS) for aggregations.
    """
  end

  @spec generate_sql(String.t()) ::
          {:ok, String.t()}
          | {:error, :cannot_answer}
          | {:error, :timeout}
          | {:error, :unavailable}
          | {:error, :not_understood}
  def generate_sql(question) when is_binary(question) do
    body = Jason.encode!(%{
      model: @model,
      prompt: question,
      system: system_prompt(),
      stream: false,
      options: %{temperature: 0.1, top_p: 0.9, num_predict: 200}
    })

    case tcp_post(body) do
      {:ok, response_body} ->
        case Jason.decode(response_body) do
          {:ok, %{"response" => raw}} ->
            parse_response(raw)

          {:ok, other} ->
            Logger.warning("[OllamaClient] Resposta inesperada: #{inspect(other)}")
            {:error, :cannot_answer}

          {:error, reason} ->
            Logger.warning("[OllamaClient] JSON invalido: #{inspect(reason)} | body: #{String.slice(response_body, 0, 120)}")
            {:error, :cannot_answer}
        end

      {:error, reason} ->
        Logger.warning("[OllamaClient] Falha TCP: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP/1.0 via :gen_tcp puro
  # HTTP/1.0: sem chunked encoding, servidor fecha conexao ao terminar
  # ---------------------------------------------------------------------------

  defp tcp_post(body) do
    content_length = byte_size(body)

    request =
      "POST #{@ollama_path} HTTP/1.0\r\n" <>
        "Host: localhost:#{@ollama_port}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Content-Length: #{content_length}\r\n" <>
        "\r\n" <>
        body

    case :gen_tcp.connect(@ollama_host, @ollama_port, [:binary, active: false], @connect_timeout) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, request)
        result = recv_all(socket, "")
        :gen_tcp.close(socket)

        case result do
          {:ok, raw} -> extract_body(raw)
          err -> err
        end

      {:error, :econnrefused} -> {:error, :unavailable}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_body(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [_headers, body] -> {:ok, String.trim(body)}
      _ -> {:error, :malformed_response}
    end
  end

  # ---------------------------------------------------------------------------
  # Parse da resposta SQL
  # ---------------------------------------------------------------------------

  defp parse_response(raw) do
    sql =
      raw
      |> String.trim()
      |> String.replace(~r/```sql\s*/i, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    cond do
      sql == "CANNOT_ANSWER" or sql == "" ->
        {:error, :cannot_answer}

      String.match?(sql, ~r/^\s*(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE)/i) ->
        Logger.warning("[OllamaClient] Modelo gerou DML, rejeitado: #{sql}")
        {:error, :cannot_answer}

      true ->
        {:ok, sql}
    end
  end
end
