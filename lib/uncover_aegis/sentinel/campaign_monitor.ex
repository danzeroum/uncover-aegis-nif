defmodule UncoverAegis.Sentinel.CampaignMonitor do
  @moduledoc """
  GenServer que monitora os gastos de uma unica campanha de marketing.

  ## Responsabilidades

  1. **Manter historico** dos ultimos `@max_history` gastos em memoria
     (Ring Buffer — evita crescimento ilimitado e OOM em processos long-running).

  2. **Delegar matematica** ao Rust: a cada novo gasto, envia o historico
     para `Native.calculate_zscore/1` (NIF DirtyCpu) que retorna o Z-Score
     do ultimo valor em relacao a media historica.

  3. **Disparar alertas** quando |Z-Score| > `@zscore_threshold` (3.0).
     Emite broadcast via Phoenix.PubSub para notificar o LiveView em
     tempo real (MVP4). Em producao: substituir por Slack/PagerDuty.
  """

  use GenServer
  require Logger

  alias UncoverAegis.Native

  @zscore_threshold 3.0
  @max_history 50

  # ---------------------------------------------------------------------------
  # API Publica
  # ---------------------------------------------------------------------------

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(campaign_id) do
    GenServer.start_link(__MODULE__, campaign_id, name: via_tuple(campaign_id))
  end

  @spec add_spend(String.t(), number()) :: :ok
  def add_spend(campaign_id, amount) do
    GenServer.cast(via_tuple(campaign_id), {:add_spend, amount / 1.0})
  end

  @spec get_history(String.t()) :: [float()]
  def get_history(campaign_id) do
    GenServer.call(via_tuple(campaign_id), :get_history)
  end

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
    new_spends = (state.spends ++ [amount]) |> Enum.take(-@max_history)

    new_state =
      case Native.calculate_zscore(new_spends) do
        {:ok, z_score} when abs(z_score) > @zscore_threshold ->
          Logger.warning(
            "[AEGIS SENTINEL] \u{1F6A8} Anomalia na campanha '#{state.campaign_id}': " <>
              "Z-Score = #{Float.round(z_score, 2)} " <>
              "| Gasto atual: R$ #{amount} " <>
              "| Historico (#{length(new_spends)} pontos)"
          )

          # MVP 4: broadcast para o LiveView via PubSub
          Phoenix.PubSub.broadcast(
            UncoverAegis.PubSub,
            "anomalies",
            {:anomaly, state.campaign_id, z_score}
          )

          %{state | spends: new_spends, last_z_score: z_score, alert_count: state.alert_count + 1}

        {:ok, z_score} ->
          %{state | spends: new_spends, last_z_score: z_score}

        {:insufficient_data, _} ->
          %{state | spends: new_spends}

        {:error, reason} ->
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

  defp via_tuple(campaign_id) do
    {:global, {:campaign_monitor, campaign_id}}
  end
end
