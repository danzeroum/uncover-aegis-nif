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
     Emite dois broadcasts via Phoenix.PubSub:
     - `"anomalies"` → LiveView (InsightsLive, aba Sentinel)
     - `"sentinel:#{campaign_id}"` → GraphQL subscription (Absinthe)
  """

  use GenServer
  require Logger

  alias UncoverAegis.Native

  @zscore_threshold 3.0
  @max_history 50

  # ---------------------------------------------------------------------------
  # API Pública
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
              "| Histórico (#{length(new_spends)} pontos)"
          )

          alert_payload = %{
            campaign_id: state.campaign_id,
            z_score: z_score,
            spend: amount,
            severity: if(abs(z_score) >= 4.0, do: "critical", else: "warning"),
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          # Broadcast 1: LiveView (aba Sentinel — comportamento existente)
          Phoenix.PubSub.broadcast(
            UncoverAegis.PubSub,
            "anomalies",
            {:anomaly, state.campaign_id, z_score}
          )

          # Broadcast 2: GraphQL Subscription (Absinthe — novo)
          # Tópico granular por campanha permite filtro no cliente
          Phoenix.PubSub.broadcast(
            UncoverAegis.PubSub,
            "sentinel:#{state.campaign_id}",
            alert_payload
          )

          # Broadcast 3: tópico global para subscriptions sem filtro
          Phoenix.PubSub.broadcast(
            UncoverAegis.PubSub,
            "sentinel:all",
            alert_payload
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
