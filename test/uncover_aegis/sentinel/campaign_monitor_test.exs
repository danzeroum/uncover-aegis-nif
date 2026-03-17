defmodule UncoverAegis.Sentinel.CampaignMonitorTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Testes do MVP 3 — Spend Anomaly Sentinel.

  `async: false` porque os testes compartilham o registro `:global`
  (processo nomeado por campaign_id). Testes concorrentes com o mesmo
  ID causariam corrida de condição no registro.
  """

  import ExUnit.CaptureLog

  alias UncoverAegis.Sentinel
  alias UncoverAegis.Sentinel.{CampaignMonitor, DynamicSupervisor}

  # Gera um ID único por teste para evitar vazáveis entre testes.
  # Cada teste trabalha com sua própria campanha isolada.
  setup do
    campaign_id = "test-#{System.unique_integer([:positive])}"
    on_exit(fn -> DynamicSupervisor.stop_campaign(campaign_id) end)
    {:ok, campaign_id: campaign_id}
  end

  # ---------------------------------------------------------------------------
  # Ciclo de vida
  # ---------------------------------------------------------------------------
  describe "ciclo de vida do monitor" do
    test "inicia monitoramento com sucesso", %{campaign_id: id} do
      assert :ok = Sentinel.start_monitoring(id)
    end

    test "start_monitoring e idempotente (pode chamar N vezes)", %{campaign_id: id} do
      assert :ok = Sentinel.start_monitoring(id)
      assert :ok = Sentinel.start_monitoring(id)
      assert :ok = Sentinel.start_monitoring(id)
    end

    test "historico inicia vazio", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)
      assert [] = CampaignMonitor.get_history(id)
    end

    test "stop_campaign encerra o processo graciosamente", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)
      assert :ok = DynamicSupervisor.stop_campaign(id)
      # Apos parar, :global nao deve encontrar o processo
      Process.sleep(50)
      assert :undefined = :global.whereis_name({:campaign_monitor, id})
    end

    test "stop_campaign e idempotente para campanha inexistente", %{campaign_id: id} do
      assert :ok = DynamicSupervisor.stop_campaign(id)
    end
  end

  # ---------------------------------------------------------------------------
  # Registro de gastos
  # ---------------------------------------------------------------------------
  describe "registro de gastos" do
    test "adiciona gastos e acumula historico", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      Sentinel.add_spend(id, 100.0)
      Sentinel.add_spend(id, 102.0)
      Sentinel.add_spend(id, 98.0)

      # Cast e assíncrono; aguarda processamento
      Process.sleep(100)

      history = CampaignMonitor.get_history(id)
      assert length(history) == 3
      assert 100.0 in history
      assert 102.0 in history
      assert 98.0 in history
    end

    test "add_spend inicia monitor automaticamente (lazy)", %{campaign_id: id} do
      # Nao chama start_monitoring explicitamente
      :ok = Sentinel.add_spend(id, 50.0)

      Process.sleep(100)

      assert [50.0] = CampaignMonitor.get_history(id)
    end

    test "aceita valores inteiros (converte para float)", %{campaign_id: id} do
      :ok = Sentinel.add_spend(id, 200)

      Process.sleep(100)

      [value] = CampaignMonitor.get_history(id)
      assert is_float(value)
      assert value == 200.0
    end
  end

  # ---------------------------------------------------------------------------
  # Ring buffer (prevencao de OOM)
  # ---------------------------------------------------------------------------
  describe "ring buffer (@max_history = 50)" do
    test "nao excede 50 elementos no historico", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      # Insere 60 gastos (10 acima do limite)
      Enum.each(1..60, fn i -> Sentinel.add_spend(id, i * 1.0) end)

      Process.sleep(200)

      history = CampaignMonitor.get_history(id)
      assert length(history) == 50
    end

    test "ring buffer preserva os ULTIMOS valores", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      # Insere 55 gastos: os primeiros 5 devem ser descartados
      Enum.each(1..55, fn i -> Sentinel.add_spend(id, i * 1.0) end)

      Process.sleep(200)

      history = CampaignMonitor.get_history(id)
      # Deve conter de 6.0 a 55.0 (os 50 ultimos)
      assert hd(history) == 6.0
      assert List.last(history) == 55.0
    end
  end

  # ---------------------------------------------------------------------------
  # Deteccao de anomalias
  # ---------------------------------------------------------------------------
  describe "deteccao de anomalias" do
    test "nao dispara alerta para gastos uniformes", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      log =
        capture_log(fn ->
          Enum.each(1..10, fn _ -> Sentinel.add_spend(id, 100.0) end)
          Process.sleep(200)
        end)

      refute log =~ "AEGIS SENTINEL"
    end

    test "dispara alerta de Logger quando z-score excede 3.0", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      log =
        capture_log(fn ->
          # Gastos normais: media ~100
          Enum.each(1..10, fn _ -> Sentinel.add_spend(id, 100.0) end)
          # Pico anomalo: 10x a media -> Z-Score >> 3.0
          Sentinel.add_spend(id, 1_000.0)
          Process.sleep(200)
        end)

      assert log =~ "AEGIS SENTINEL"
      assert log =~ id
      assert log =~ "Z-Score"
    end

    test "incrementa alert_count a cada anomalia detectada", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      # Historico estavel
      Enum.each(1..10, fn _ -> Sentinel.add_spend(id, 100.0) end)
      # Duas anomalias consecutivas
      Sentinel.add_spend(id, 5_000.0)
      Sentinel.add_spend(id, 5_000.0)

      Process.sleep(200)

      state = CampaignMonitor.get_state(id)
      assert state.alert_count >= 1
    end

    test "last_z_score e atualizado apos cada gasto", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      Sentinel.add_spend(id, 100.0)
      Sentinel.add_spend(id, 100.0)
      Sentinel.add_spend(id, 100.0)

      Process.sleep(100)

      state = CampaignMonitor.get_state(id)
      assert is_float(state.last_z_score)
    end

    test "insufficient_data para historico com 1 elemento", %{campaign_id: id} do
      :ok = Sentinel.start_monitoring(id)

      # Apenas 1 gasto: Rust retorna :insufficient_data, nao deve crashar
      log =
        capture_log(fn ->
          Sentinel.add_spend(id, 100.0)
          Process.sleep(100)
        end)

      # Sem crash, sem alerta
      refute log =~ "AEGIS SENTINEL"
      refute log =~ "Erro"
    end
  end

  # ---------------------------------------------------------------------------
  # Isolamento de falhas ("Let it crash")
  # ---------------------------------------------------------------------------
  describe "isolamento OTP" do
    test "monitores de campanhas diferentes sao processos independentes", %{campaign_id: id} do
      id2 = "#{id}-other"
      on_exit(fn -> DynamicSupervisor.stop_campaign(id2) end)

      :ok = Sentinel.start_monitoring(id)
      :ok = Sentinel.start_monitoring(id2)

      Sentinel.add_spend(id, 100.0)
      Sentinel.add_spend(id2, 200.0)

      Process.sleep(100)

      assert [100.0] = CampaignMonitor.get_history(id)
      assert [200.0] = CampaignMonitor.get_history(id2)
    end
  end
end
