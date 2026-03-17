defmodule UncoverAegis.Insights do
  @moduledoc """
  Orquestra a geração segura de insights de campanhas combinando:

  1. **SQL Guardrail (Rust)**: valida que a query gerada pelo LLM é somente
     de leitura antes de executar no banco. Protege contra alucinações da IA.

  2. **Ecto Query (Elixir)**: executa a query validada no SQLite com
     o pool de conexões gerenciado pelo Supervisor OTP.

  3. **Z-Score Anomaly Detection (Rust)**: calcula o desvio estatístico
     dos gastos retornados, alertando quando um valor é anomalia.

  ## Fluxo

  ```
  SQL (do LLM)
       |
       v
  Native.validate_read_only_sql/1   <- Rust: guardrail de segurança
       |
       v
  Repo.query/2                       <- Elixir: execução no banco
       |
       v
  Native.calculate_zscore/1          <- Rust: detecção de anomalia
       |
       v
  {:ok, %{rows: [...], anomaly: bool, z_score: float}}
  ```
  """

  alias UncoverAegis.{Native, Repo}

  @zscore_threshold 3.0

  @doc """
  Executa uma query SQL (geralmente gerada por LLM) de forma segura.

  Valida o SQL via NIF Rust antes de qualquer interação com o banco.
  Retorna as linhas da query e metadados de anomalia nos gastos.

  ## Retorno

      {:ok, %{rows: list(), columns: list(), z_score: float(), anomaly: boolean()}}
      {:error, reason :: String.t()}
      {:unsafe_sql, reason :: String.t()}

  ## Exemplo

      iex> UncoverAegis.Insights.run_safe_query(
      ...>   "SELECT campaign_id, spend FROM campaign_metrics WHERE platform = 'meta'"
      ...> )
      {:ok, %{rows: [...], columns: [...], z_score: 0.5, anomaly: false}}

  """
  @spec run_safe_query(String.t()) ::
          {:ok, map()}
          | {:error, String.t()}
          | {:unsafe_sql, String.t()}
  def run_safe_query(sql) when is_binary(sql) do
    # Etapa 1: guardrail Rust — bloqueia antes de tocar no banco
    case Native.validate_read_only_sql(sql) do
      {:ok, validated_sql} ->
        execute_and_analyze(validated_sql)

      {:unsafe_sql, reason} ->
        {:unsafe_sql, reason}

      {:error, reason} ->
        {:error, "Motor de validação indisponível: #{reason}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

  # Executa a query validada e calcula z-score nos gastos retornados.
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
        {:error, "Erro na execução da query: #{inspect(reason)}"}
    end
  end

  # Extrai coluna 'spend' das linhas retornadas pelo Ecto (como float).
  # Retorna lista vazia se a coluna não existir no resultado.
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

  # Delega o cálculo de z-score para o Rust e determina se há anomalia.
  defp analyze_spends([]), do: {0.0, false}

  defp analyze_spends(spends) do
    case Native.calculate_zscore(spends) do
      {:ok, z} -> {z, abs(z) > @zscore_threshold}
      {:insufficient_data, _} -> {0.0, false}
      {:error, _} -> {0.0, false}
    end
  end
end
