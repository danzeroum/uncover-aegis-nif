defmodule UncoverAegis.Insights.OllamaClient do
  @moduledoc """
  Cliente HTTP para o Ollama rodando localmente.
  Usa :gen_tcp com timeout de 60s para cobrir cold start do qwen2.5-coder:7b.
  """

  require Logger

  @ollama_host ~c"localhost"
  @ollama_port 11434
  @ollama_path "/api/generate"
  @model "qwen2.5-coder:7b"
  # 60s para cobrir cold start do modelo 7b
  @connect_timeout 5_000
  @recv_timeout 60_000

  @system_prompt """
  You are a SQL expert for a marketing analytics platform.
  Your ONLY job is to convert natural language questions into SQL SELECT queries.

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
    - date DATE NOT NULL

  STRICT RULES:
  1. Respond with ONLY the SQL query. No explanation, no markdown, no code blocks.
  2. ONLY generate SELECT queries. Never INSERT, UPDATE, DELETE, DROP, CREATE, or ALTER.
  3. If you cannot answer with a SELECT, respond with exactly: CANNOT_ANSWER
  4. Use standard SQLite syntax.
  5. Always use meaningful column aliases (AS) for aggregations.
  """

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
      system: @system_prompt,
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
          {:error, _} ->
            # Pode ser chunked encoding -- tenta extrair JSON do body bruto
            parse_chunked_body(response_body)
        end

      {:error, reason} ->
        Logger.warning("[OllamaClient] Falha TCP: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP/1.1 via :gen_tcp puro
  # ---------------------------------------------------------------------------

  defp tcp_post(body) do
    content_length = byte_size(body)

    request =
      "POST #{@ollama_path} HTTP/1.1\r\n" <>
      "Host: localhost:#{@ollama_port}\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{content_length}\r\n" <>
      "Connection: close\r\n" <>
      "\r\n" <>
      body

    case :gen_tcp.connect(@ollama_host, @ollama_port, [:binary, active: false], @connect_timeout) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, request)
        # seta timeout de recepcao no socket
        :inet.setopts(socket, [{:send_timeout, @recv_timeout}])
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

  # Ollama pode retornar chunked transfer encoding
  # Nesse caso o body contem tamanho do chunk em hex antes do JSON
  defp parse_chunked_body(body) do
    # Tenta encontrar JSON valido removendo prefixos de chunk hex
    cleaned =
      body
      |> String.replace(~r/^[0-9a-fA-F]+\r\n/, "")
      |> String.replace(~r/\r\n[0-9a-fA-F]+\r\n/, "")
      |> String.replace("\r\n", "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"response" => raw}} -> parse_response(raw)
      _ ->
        Logger.warning("[OllamaClient] Nao conseguiu parsear body chunked: #{String.slice(body, 0, 100)}")
        {:error, :cannot_answer}
    end
  end

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
