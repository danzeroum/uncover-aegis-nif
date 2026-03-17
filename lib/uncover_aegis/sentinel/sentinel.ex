defmodule UncoverAegis.Sentinel do
  @moduledoc """
  API pública para o monitoramento preditivo de anomalias de gastos (MVP 3).

  ## Arquitetura

  ```
  UncoverAegis.Sentinel          <- API pública (este módulo)
       |
       v
  Sentinel.DynamicSupervisor     <- Supervisor dinâmico (1 por aplicação)
       |
       v
  Sentinel.CampaignMonitor       <- GenServer (1 por campanha ativa)
       |
       v
  Native.calculate_zscore/1      <- NIF Rust: matemática em microssegundos
  ```

  A filosofia "Let it crash" garante que a falha de um monitor
  (ex: corrupção de estado) não afeta as outras campanhas.

  ## Uso

      # Iniciar monitoramento explicitamente
      :ok = UncoverAegis.Sentinel.start_monitoring("summer_sale")

      # Ou implicitamente ao adicionar o primeiro gasto
      :ok = UncoverAegis.Sentinel.add_spend("summer_sale", 1000.0)

      # Consultar histórico
      UncoverAegis.Sentinel.CampaignMonitor.get_history("summer_sale")
      #=> [1000.0]

  """

  alias UncoverAegis.Sentinel.{DynamicSupervisor, CampaignMonitor}

  @doc """
  Inicia o monitoramento para uma campanha específica.

  Operação idempotente: se o monitor já estiver rodando, retorna `:ok`
  sem criar um segundo processo.

  ## Retorno
  - `:ok` — monitor iniciado ou já existente.
  - `{:error, reason}` — falha ao iniciar o processo filho.
  """
  @spec start_monitoring(String.t()) :: :ok | {:error, term()}
  def start_monitoring(campaign_id) when is_binary(campaign_id) do
    DynamicSupervisor.start_campaign(campaign_id)
  end

  @doc """
  Registra um novo gasto para a campanha e dispara análise de anomalia.

  Se a campanha não estiver sendo monitorada, ela é iniciada automaticamente
  antes de registrar o gasto (comportamento lazy e idempotente).

  A análise Z-Score é **assíncrona** (via `GenServer.cast`): a função
  retorna imediatamente sem esperar o resultado do cálculo Rust.

  ## Retorno
  - `:ok` — gasto enfileirado para processamento.
  - `{:error, reason}` — falha ao iniciar o monitor.
  """
  @spec add_spend(String.t(), number()) :: :ok | {:error, term()}
  def add_spend(campaign_id, amount) when is_binary(campaign_id) and is_number(amount) do
    with :ok <- start_monitoring(campaign_id) do
      CampaignMonitor.add_spend(campaign_id, amount)
    end
  end
end
