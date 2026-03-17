defmodule UncoverAegis.Sentinel.CampaignMonitorTest do
  @moduledoc """
  Testes do CampaignMonitor (MVP3 - Sentinel).

  Verifica o comportamento do GenServer que monitora gastos
  em tempo real e detecta anomalias via Z-Score Rust.
  """
  use ExUnit.Case, async: true

  alias UncoverAegis.Sentinel.CampaignMonitor

  describe "CampaignMonitor" do
    test "inicia com estado vazio" do
      {:ok, pid} = CampaignMonitor.start_link(campaign_id: "test_camp_#{System.unique_integer()}")
      state = :sys.get_state(pid)
      assert state.spends == []
      assert state.anomaly_detected == false
    end

    test "acumula spends corretamente" do
      campaign_id = "test_camp_#{System.unique_integer()}"
      {:ok, pid} = CampaignMonitor.start_link(campaign_id: campaign_id)

      CampaignMonitor.add_spend(campaign_id, 100.0)
      CampaignMonitor.add_spend(campaign_id, 200.0)
      CampaignMonitor.add_spend(campaign_id, 150.0)

      state = :sys.get_state(pid)
      assert length(state.spends) == 3
      assert 100.0 in state.spends
    end

    test "nao marca anomalia para valores uniformes" do
      campaign_id = "test_camp_#{System.unique_integer()}"
      {:ok, _pid} = CampaignMonitor.start_link(campaign_id: campaign_id)

      Enum.each(1..6, fn _ ->
        CampaignMonitor.add_spend(campaign_id, 1000.0 + :rand.uniform() * 10)
      end)

      state = :sys.get_state(campaign_id |> CampaignMonitor.via_tuple())
      assert state.anomaly_detected == false
    end

    test "detecta anomalia com outlier extremo" do
      campaign_id = "test_camp_#{System.unique_integer()}"
      {:ok, _pid} = CampaignMonitor.start_link(campaign_id: campaign_id)

      # 5 valores normais
      Enum.each(1..5, fn _ -> CampaignMonitor.add_spend(campaign_id, 1000.0) end)
      # outlier extremo
      CampaignMonitor.add_spend(campaign_id, 999_000.0)

      # Pequena espera para o GenServer processar (cast é async)
      Process.sleep(50)

      state = :sys.get_state(campaign_id |> CampaignMonitor.via_tuple())
      assert state.anomaly_detected == true
    end
  end
end
