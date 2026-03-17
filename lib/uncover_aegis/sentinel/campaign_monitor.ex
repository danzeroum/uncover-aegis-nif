defmodule UncoverAegis.Sentinel.CampaignMonitor do
  @moduledoc """
  GenServer que monitora os gastos de uma única campanha de marketing.

  ## Responsabilidades

  1. **Manter histórico** dos últimos `@max_history` gastos em memória
     (Ring Buffer — evita crescimento ilimitado e OOM em processos long-running).

  2. **Delegar matemática** ao Rust: a cada novo gasto, envia o histórico
     para `Native.calculate_zscore/1` (NIF DirtyCpu) que retorna o Z-Score
     do último valor em relação à média histórica.

  3. **Disparar alertas** quando |Z-Score| > `@zscore_threshold` (3.0).
     Em produção: substituir `IO.puts` por integração com Slack/PagerDuty.

  ## Por que 1 GenServer por campanha?

  Em vez de um banco centralizado com queries GROUP BY, o estado vive
  na memória RAM do processo. Isso elimina latência de I/O para o hot path
  de monitoramento e isola falhas: um crash nesta campanha não afeta outras.

  ## Registro

  Usa `:global` para registro de nomes, permitindo expansão futura
  para clusters distribuídos sem alterar a API pública.
  """

  use GenServer
  require Logger

  alias UncoverAegis.Native

  # Z-Score > 3.0 corresponde a 99.7% de confiança estatística (3-sigma rule)
  @zscore_threshold 3.0
  # Ring buffer: mantemos apenas os últimos 50 gastos para evitar OOM.
  # Em produção, este valor pode ser configurado por campanha.
  @max_history 50

  # ---------------------------------------------------------------------------
  # API Pública
  # ---------------------------------------------------------------------------

  @doc """
  Inicia o GenServer para uma campanha. Chamado pelo DynamicSupervisor.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(campaign_id) do
    GenServer.start_link(__MODULE__, campaign_id, name: via_tuple(campaign_id))
  end

  @doc """
  Enfileira um novo gasto para análise. Operação assíncrona (cast).
  Retorna `:ok` imediatamente, sem bloquear o processo chamador.
  """
  @spec add_spend(String.t(), number()) :: :ok
  def add_spend(campaign_id, amount) do
    GenServer.cast(via_tuple(campaign_id), {:add_spend, amount / 1.0})
  end

  @doc """
  Retorna o histórico de gastos atual da campanha. Operação síncrona (call).
  """
  @spec get_history(String.t()) :: [float()]
  def get_history(campaign_id) do
    GenServer.call(via_tuple(campaign_id), :get_history)
  end

  @doc """
  Retorna o estado interno completo (para debug e testes).
  """
  @spec get_state(String.t()) :: map()
  def get_state(campaign_id) do
    GenServer.call(via_tuple(campaign_id), :get_state)
  end

  # ---------------------------------------------------------------------------
  # Callbacks do GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(campaign_id) do
    Logger.info("[Sentinel] Monitor iniciado para campanha: #{campaign_id}")

    {:ok,
     %{
       campaign_id: campaign_id,
       spends: [],
       alert_count: 0,
       last_z_score: 0.0
     }}
  end

  @impl true
  def handle_cast({:add_spend, amount}, state) do
    # Ring buffer: concatena e trunca para @max_history elementos.
    # Enum.take(-N) é O(N) mas N é fixo (max 50), então custo é constante.
    new_spends = (state.spends ++ [amount]) |> Enum.take(-@max_history)

    # Delega o cálculo ao Rust (NIF DirtyCpu — não bloqueia o scheduler).
    new_state =
      case Native.calculate_zscore(new_spends) do
        {:ok, z_score} when abs(z_score) > @zscore_threshold ->
          # Anomalia detectada: alerta e incrementa contador.
          Logger.warning(
            "[AEGIS SENTINEL] 🚨 Anomalia na campanha '#{state.campaign_id}': " <>
              "Z-Score = #{Float.round(z_score, 2)} " <>
              "| Gasto atual: R$ #{amount} " <>
              "| Histórico (#{length(new_spends)} pontos)"
          )

          %{state | spends: new_spends, last_z_score: z_score, alert_count: state.alert_count + 1}

        {:ok, z_score} ->
          # Gasto dentro do esperado.
          %{state | spends: new_spends, last_z_score: z_score}

        {:insufficient_data, _} ->
          # Menos de 2 pontos: ainda coletando histórico inicial.
          %{state | spends: new_spends}

        {:error, reason} ->
          # Falha no motor Rust: Fail-Secure (não processa, não crasha).
          Logger.error("[Sentinel] Erro no motor Z-Score: #{reason}")
          %{state | spends: new_spends}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.spends, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "[Sentinel] Monitor encerrado para '#{state.campaign_id}'. Motivo: #{inspect(reason)}"
    )
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

  # Registro via :global permite futuro uso em cluster Erlang distribuído
  # sem alterar a API pública. Para deploy single-node, Registry local é
  # mais eficiente, mas :global é mais didático para a apresentação.
  defp via_tuple(campaign_id) do
    {:global, {:campaign_monitor, campaign_id}}
  end
end
