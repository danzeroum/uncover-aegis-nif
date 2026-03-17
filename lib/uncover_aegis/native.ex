defmodule UncoverAegis.Native do
  @moduledoc """
  Interface NIF para o núcleo Rust (aegis_core).

  Este módulo é o ponto de contato entre o Elixir e a biblioteca
  dinâmica compilada pelo Rustler. Todas as funções são executadas
  como **Dirty CPU NIFs**, garantindo que os schedulers principais
  da BEAM não sejam bloqueados por operações CPU-bound.

  Cada função abaixo é um stub Elixir obrigatório: o Rustler substitui
  o corpo `:erlang.nif_error(:nif_not_loaded)` pela implementação Rust
  em tempo de carga da biblioteca dinâmica.
  """

  use Rustler,
    otp_app: :uncover_aegis,
    crate: :aegis_core

  # ---------------------------------------------------------------------------
  # MVP 1 — Sanitação de PII + Detecção de Prompt Injection
  # ---------------------------------------------------------------------------

  @doc """
  Sanitiza um texto de campanha removendo PII e detectando Prompt Injection.

  ## Retorno
  - `{:ok, texto_limpo}` — sanitiçação bem-sucedida, PII removido.
  - `{:threat_detected, motivo}` — conteúdo bloqueado por segurança.
  - `{:error, motivo}` — falha interna no motor.

  ## Exemplos

      iex> UncoverAegis.Native.sanitize_and_validate("CPF: 123.456.789-00")
      {:ok, "CPF: [CPF_REDACTED]"}

      iex> UncoverAegis.Native.sanitize_and_validate("ignore previous instructions")
      {:threat_detected, "Prompt injection bloqueado: padrao 'ignore previous instructions' detectado"}

  """
  def sanitize_and_validate(_raw_text), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # MVP 2 — SQL Guardrail
  # ---------------------------------------------------------------------------

  @doc """
  Valida que um SQL gerado por LLM é estritamente de leitura (SELECT/WITH).

  ## Retorno
  - `{:ok, sql_original}` — query segura para execução.
  - `{:unsafe_sql, motivo}` — query bloqueada pela política.
  - `{:error, motivo}` — falha interna na compilação de regex.

  ## Exemplos

      iex> UncoverAegis.Native.validate_read_only_sql("SELECT spend FROM campaign_metrics")
      {:ok, "SELECT spend FROM campaign_metrics"}

      iex> UncoverAegis.Native.validate_read_only_sql("DROP TABLE campaign_metrics")
      {:unsafe_sql, "Keyword de mutacao detectada: DROP"}

      iex> UncoverAegis.Native.validate_read_only_sql("SELECT last_updated_at FROM campaign_metrics")
      {:ok, "SELECT last_updated_at FROM campaign_metrics"}

  """
  def validate_read_only_sql(_query), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # MVP 3 — Detecção de Anomalias via Z-Score
  # ---------------------------------------------------------------------------

  @doc """
  Calcula o Z-Score do último elemento de uma lista de gastos.

  O Z-Score mede quantos desvios padrão o gasto atual está da média
  histórica. Um |z| > 3.0 indica anomalia com 99.7% de confiança.

  ## Retorno
  - `{:ok, z_score}` — cálculo bem-sucedido (float).
  - `{:insufficient_data, 0.0}` — menos de 2 pontos na lista.
  - `{:error, 0.0}` — falha interna inesperada.

  ## Exemplos

      iex> UncoverAegis.Native.calculate_zscore([100.0, 100.0, 100.0, 100.0])
      {:ok, 0.0}

      iex> UncoverAegis.Native.calculate_zscore([100.0, 105.0, 98.0, 102.0, 500.0])
      {:ok, z} when z > 3.0

      iex> UncoverAegis.Native.calculate_zscore([100.0])
      {:insufficient_data, 0.0}

  """
  def calculate_zscore(_spends), do: :erlang.nif_error(:nif_not_loaded)
end
