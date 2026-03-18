defmodule UncoverAegis.Native do
  @moduledoc """
  Interface NIF para o núcleo Rust (aegis_core).

  Todas as funções são executadas como **Dirty CPU NIFs**, garantindo que
  os schedulers principais da BEAM não sejam bloqueados por operações CPU-bound.
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
  - `{:ok, texto_limpo}` — sanitização bem-sucedida, PII removido.
  - `{:threat_detected, motivo}` — conteúdo bloqueado por segurança.
  - `{:error, motivo}` — falha interna no motor.
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
  """
  def validate_read_only_sql(_query), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # MVP 3 — Detecção de Anomalias via Z-Score
  # ---------------------------------------------------------------------------

  @doc """
  Calcula o Z-Score do último elemento de uma lista de gastos.

  ## Retorno
  - `{:ok, z_score}` — cálculo bem-sucedido (float).
  - `{:insufficient_data, 0.0}` — menos de 2 pontos na lista.
  - `{:error, 0.0}` — falha interna inesperada.
  """
  def calculate_zscore(_spends), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # MVP 4 — Marketing Mix Modeling: Adstock com Saturação Hill
  # ---------------------------------------------------------------------------

  @doc """
  Calcula o Adstock de uma série temporal de gastos com carry-over
  geométrico e saturação Hill — o algoritmo central do MMM.

  ## Parâmetros
  - `spends` — lista de gastos por período (ex: spend diário)
  - `decay` — taxa de retenção do efeito entre períodos (0.0 a 1.0)
    - `0.0` → sem memória (efeito apenas no dia)
    - `0.7` → padrão para digital; 70% do efeito persiste ao próximo período
    - `0.9` → TV/offline; efeito persiste por semanas
  - `alpha` — expoente Hill; controla forma da curva de saturação (> 0)
    - `1.0` → curva convexa simples
    - `2.0` → curva em S (recomendado para digital)
  - `half_saturation` — valor de adstock onde o impacto é 50% do máximo

  ## Retorno
  - `{:ok, %{adstock_values, saturated_values, contribution_pct}}` — sucesso
  - `{:insufficient_data, _}` — lista de spends vazia
  - `{:error, _}` — parâmetros inválidos

  ## Exemplo

      iex> UncoverAegis.Native.calculate_adstock(
      ...>   [1200.0, 1350.0, 1100.0, 1280.0],
      ...>   0.7,   # decay padrão para digital
      ...>   2.0,   # curva em S
      ...>   1500.0 # 50% de saturação em R$ 1.500
      ...> )
      {:ok, %UncoverAegis.Native.AdstockResult{
        adstock_values: [1200.0, 2190.0, 2833.0, 3063.1],
        saturated_values: [0.392, 0.680, 0.781, 0.806],
        contribution_pct: [14.6, 25.4, 29.2, 30.1]
      }}

  """
  def calculate_adstock(_spends, _decay, _alpha, _half_saturation),
    do: :erlang.nif_error(:nif_not_loaded)
end
