defmodule UncoverAegis.Insights do
  @moduledoc """
  Orquestra a geracao segura de insights de campanhas.

  ## Pipeline NL->SQL (ask/1)

  ```
  Pergunta (NL)
    -> OllamaClient.generate_sql/1   <- LLM real (qwen2.5-coder:7b)
    -> [fallback LlmMock se Ollama indisponivel]
    -> Native.validate_read_only_sql/1  <- Guardrail Rust
    -> Repo.query/2                      <- Ecto SQLite
    -> Native.calculate_zscore/1         <- Z-Score Rust
    -> {:ok, %{rows, columns, z_score, anomaly, metadata}}
  ```

  ## Pipeline SQL direto (run_safe_query/1)

  ```
  SQL
    -> Native.validate_read_only_sql/1
    -> Repo.query/2
    -> Native.calculate_zscore/1
    -> {:ok, %{rows, columns, z_score, anomaly}}
  ```
  """

  alias UncoverAegis.{Native, Repo}
  alias UncoverAegis.Insights.{LlmMock, OllamaClient}

  require Logger

  @zscore_threshold 3.0

  # ---------------------------------------------------------------------------
  # MVP 4 — Pergunta em linguagem natural
  # ---------------------------------------------------------------------------

  @doc """
  Aceita uma pergunta em linguagem natural, gera SQL via Ollama
  (com fallback para LlmMock), valida com guardrail Rust e executa.
  """
  @spec ask(String.t()) :: {:ok, map()} | {:error, atom(), String.t()}
  def ask(question) when is_binary(question) do
    with {:ok, sql} <- resolve_sql(question),
         {:ok, validated_sql, guardrail_us} <- validate_with_timing(sql),
         {:ok, result, query_ms} <- execute_with_timing(validated_sql) do
      {z_score, anomaly} = analyze_spends(extract_spends(result))

      {:ok,
       %{
         rows: result.rows,
         columns: result.columns,
         row_count: length(result.rows),
         z_score: z_score,
         anomaly: anomaly,
         metadata: %{
           sql: validated_sql,
           guardrail_us: guardrail_us,
           query_ms: query_ms
         }
       }}
    else
      {:error, :not_understood} ->
        {:error, :llm, "Pergunta nao reconhecida. Tente: 'qual o gasto total?'"}

      {:error, :cannot_answer} ->
        {:error, :llm, "Nao consegui gerar SQL para esta pergunta. Tente reformular."}

      {:error, :validation, reason} ->
        {:error, :guardrail, reason}

      {:error, :execution, reason} ->
        {:error, :database, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # MVP 2 — SQL direto (mantido para modo SQL da UI)
  # ---------------------------------------------------------------------------

  @spec run_safe_query(String.t()) ::
          {:ok, map()} | {:error, String.t()} | {:unsafe_sql, String.t()}
  def run_safe_query(sql) when is_binary(sql) do
    case Native.validate_read_only_sql(sql) do
      {:ok, validated_sql} -> execute_and_analyze(validated_sql)
      {:unsafe_sql, reason} -> {:unsafe_sql, reason}
      {:error, reason} -> {:error, "Motor de validacao indisponivel: #{reason}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

  # Tenta Ollama primeiro; se indisponivel ou timeout, cai no LlmMock.
  defp resolve_sql(question) do
    case OllamaClient.generate_sql(question) do
      {:ok, sql} ->
        Logger.debug("[Insights] Ollama gerou SQL: #{sql}")
        {:ok, sql}

      {:error, reason} when reason in [:unavailable, :timeout] ->
        Logger.warning("[Insights] Ollama #{reason}, usando LlmMock como fallback")
        LlmMock.generate_sql(question)

      {:error, :cannot_answer} ->
        # Tenta o mock antes de desistir (pode ser uma das 6 perguntas fixas)
        case LlmMock.generate_sql(question) do
          {:ok, sql} -> {:ok, sql}
          _ -> {:error, :cannot_answer}
        end

      {:error, _} ->
        LlmMock.generate_sql(question)
    end
  end

  defp validate_with_timing(sql) do
    t0 = System.monotonic_time()

    result =
      case Native.validate_read_only_sql(sql) do
        {:ok, safe_sql} -> {:ok, safe_sql}
        {:unsafe_sql, reason} -> {:error, :validation, "SQL bloqueado: #{reason}"}
        {:error, reason} -> {:error, :validation, "Erro interno: #{reason}"}
      end

    elapsed_us = System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)

    case result do
      {:ok, safe_sql} -> {:ok, safe_sql, elapsed_us}
      err -> err
    end
  end

  defp execute_with_timing(sql) do
    t0 = System.monotonic_time()

    result =
      case Repo.query(sql) do
        {:ok, r} -> {:ok, r}
        {:error, e} -> {:error, :execution, "Erro na execucao: #{inspect(e)}"}
      end

    elapsed_ms = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

    case result do
      {:ok, r} -> {:ok, r, elapsed_ms}
      err -> err
    end
  end

  defp execute_and_analyze(sql) do
    case Repo.query(sql) do
      {:ok, result} ->
        spends = extract_spends(result)
        {z_score, anomaly} = analyze_spends(spends)

        {:ok,
         %{
           rows: result.rows,
           columns: result.columns,
           row_count: length(result.rows),
           z_score: z_score,
           anomaly: anomaly,
           anomaly_threshold: @zscore_threshold
         }}

      {:error, reason} ->
        {:error, "Erro na execucao da query: #{inspect(reason)}"}
    end
  end

  defp extract_spends(%{columns: columns, rows: rows}) do
    case Enum.find_index(columns, &(&1 == "spend")) do
      nil -> []
      idx ->
        rows
        |> Enum.map(&Enum.at(&1, idx))
        |> Enum.filter(&is_number/1)
        |> Enum.map(&(&1 / 1.0))
    end
  end

  defp analyze_spends([]), do: {0.0, false}

  defp analyze_spends(spends) do
    case Native.calculate_zscore(spends) do
      {:ok, z} -> {z, abs(z) > @zscore_threshold}
      {:insufficient_data, _} -> {0.0, false}
      {:error, _} -> {0.0, false}
    end
  end
end
