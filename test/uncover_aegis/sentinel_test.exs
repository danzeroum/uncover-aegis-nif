defmodule UncoverAegis.Sentinel.CampaignMonitorTest do
  @moduledoc """
  Testes do CampaignMonitor (MVP 3 - Sentinel).
  Verifica o comportamento do GenServer que monitora gastos
  em tempo real e detecta anomalias via Z-Score Rust.
  """
  use ExUnit.Case, async: false

  alias UncoverAegis.Sentinel.{CampaignMonitor, DynamicSupervisor}

  defp unique_id, do: "test_#{System.unique_integer([:positive])}"

  defp start_monitor(campaign_id) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(%{campaign_id: campaign_id})
    campaign_id
  end

  describe "CampaignMonitor" do
    test "inicia com estado vazio" do
      id = unique_id()
      {:ok, pid} = CampaignMonitor.start_link(campaign_id: id)
      state = :sys.get_state(pid)
      assert state.spends == []
      assert state.anomaly_detected == false
    end

    test "acumula spends corretamente" do
      id = unique_id()
      {:ok, pid} = CampaignMonitor.start_link(campaign_id: id)

      CampaignMonitor.add_spend(id, 100.0)
      CampaignMonitor.add_spend(id, 200.0)
      CampaignMonitor.add_spend(id, 150.0)

      # Pequena espera para casts async serem processados
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert length(state.spends) == 3
    end

    test "nao marca anomalia para valores uniformes" do
      id = start_monitor(unique_id())
      Enum.each(1..8, fn _ -> CampaignMonitor.add_spend(id, 1000.0) end)
      Process.sleep(100)
      assert %{anomaly_detected: false} = :sys.get_state(CampaignMonitor.via_tuple(id))
    end

    test "detecta anomalia com outlier extremo" do
      id = start_monitor(unique_id())
      Enum.each(1..6, fn _ -> CampaignMonitor.add_spend(id, 1000.0) end)
      CampaignMonitor.add_spend(id, 999_000.0)
      Process.sleep(100)
      assert %{anomaly_detected: true} = :sys.get_state(CampaignMonitor.via_tuple(id))
    end
  end
end
