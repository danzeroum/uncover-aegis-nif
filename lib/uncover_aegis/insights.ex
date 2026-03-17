defmodule UncoverAegis.Insights do
  @moduledoc """
  Orquestra a geracao segura de insights de campanhas combinando:

  1. **LlmMock** (MVP4): converte pergunta em linguagem natural para SQL.

  2. **SQL Guardrail (Rust)**: valida que a query gerada pelo LLM e somente
     de leitura antes de executar no banco.

  3. **Ecto Query (Elixir)**: executa a query validada no SQLite com
     o pool de conexoes gerenciado pelo Supervisor OTP.

  4. **Z-Score Anomaly Detection (Rust)**: calcula o desvio estatistico
     dos gastos retornados, alertando quando um valor e anomalia.

  ## Fluxos

  ### ask/1 (MVP4 — pergunta em linguagem natural)
  ```
  Pergunta (NL)
    -> LlmMock.generate_sql/1
    -> Native.validate_read_only_sql/1  <- Rust guardrail
    -> Repo.query/2                      <- Ecto SQLite
    -> Native.calculate_zscore/1         <- Rust z-score
    -> {:ok, %{rows, columns, z_score, anomaly, metadata}}
  ```

  ### run_safe_query/1 (MVP2 — SQL direto)
  ```
  SQL
    -> Native.validate_read_only_sql/1
    -> Repo.query/2
    -> Native.calculate_zscore/1
    -> {:ok, %{rows, columns, z_score, anomaly}}
  ```
  """

  alias UncoverAegis.{Native, Repo}
  alias UncoverAegis.Insights.LlmMock

  @zscore_threshold 3.0

  # ---------------------------------------------------------------------------
  # MVP 4 — Pergunta em linguagem natural
  # ---------------------------------------------------------------------------

  @doc """
  Aceita uma pergunta em linguagem natural, gera SQL via LLM, valida
  com o guardrail Rust, executa no banco e retorna resultado + metadados.

  ## Retorno

      {:ok, %{
        rows: list(),
        columns: list(),
        z_score: float(),
        anomaly: boolean(),
        metadata: %{sql: String.t(), guardrail_us: integer(), query_ms: integer()}
      }}
      {:error, atom(), String.t()}

  """
  @spec ask(String.t()) ::
          {:ok, map()}
          | {:error, atom(), String.t()}
  def ask(question) when is_binary(question) do
    with {:ok, sql} <- LlmMock.generate_sql(question),
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

      {:error, :validation, reason} ->
        {:error, :guardrail, reason}

      {:error, :execution, reason} ->
        {:error, :database, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # MVP 2 — SQL direto (mantido para compatibilidade)
  # ---------------------------------------------------------------------------

  @doc """
  Executa uma query SQL (geralmente gerada por LLM) de forma segura.
  """
  @spec run_safe_query(String.t()) ::
          {:ok, map()}
          | {:error, String.t()}
          | {:unsafe_sql, String.t()}
  def run_safe_query(sql) when is_binary(sql) do
    case Native.validate_read_only_sql(sql) do
      {:ok, validated_sql} ->
        execute_and_analyze(validated_sql)

      {:unsafe_sql, reason} ->
        {:unsafe_sql, reason}

      {:error, reason} ->
        {:error, "Motor de validacao indisponivel: #{reason}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

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
      nil ->
        []

      idx ->
        rows
        |> Enum.map(fn row -> Enum.at(row, idx) end)
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
