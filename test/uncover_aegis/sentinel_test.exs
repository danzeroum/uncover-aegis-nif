defmodule UncoverAegis.Sentinel.CampaignMonitorTest do
  @moduledoc """
  Testes do CampaignMonitor (MVP 3 - Sentinel).

  Verifica o comportamento do GenServer que monitora gastos
  em tempo real e detecta anomalias via Z-Score Rust.

  Nota de design: o estado usa `alert_count` para rastrear anomalias
  (incrementado a cada Z-Score > 3.0) e `last_z_score` para o Z mais recente.
  """
  use ExUnit.Case, async: false

  alias UncoverAegis.Sentinel.{CampaignMonitor, DynamicSupervisor}

  defp unique_id, do: "test_#{System.unique_integer([:positive])}"

  defp start_monitor(campaign_id) do
    :ok = DynamicSupervisor.start_campaign(campaign_id)
    campaign_id
  end

  describe "CampaignMonitor" do
    test "inicia com estado vazio" do
      id = unique_id()
      {:ok, _pid} = CampaignMonitor.start_link(id)
      state = CampaignMonitor.get_state(id)
      assert state.spends == []
      assert state.alert_count == 0
      assert state.last_z_score == 0.0
    end

    test "acumula spends corretamente" do
      id = unique_id()
      {:ok, _pid} = CampaignMonitor.start_link(id)

      CampaignMonitor.add_spend(id, 100.0)
      CampaignMonitor.add_spend(id, 200.0)
      CampaignMonitor.add_spend(id, 150.0)

      # get_state e um call sincrono: garante que os casts anteriores foram processados
      state = CampaignMonitor.get_state(id)
      assert length(state.spends) == 3
      assert 100.0 in state.spends
      assert 200.0 in state.spends
    end

    test "nao marca anomalia para valores uniformes" do
      id = start_monitor(unique_id())
      Enum.each(1..8, fn _ -> CampaignMonitor.add_spend(id, 1000.0) end)
      # get_state e sincrono: garante processamento dos casts
      state = CampaignMonitor.get_state(id)
      assert state.alert_count == 0
    end

    test "detecta anomalia com outlier extremo e incrementa alert_count" do
      id = start_monitor(unique_id())
      # 6 valores uniformes para estabelecer baseline
      Enum.each(1..6, fn _ -> CampaignMonitor.add_spend(id, 1000.0) end)
      # Outlier extremo: 100x a media
      CampaignMonitor.add_spend(id, 100_000.0)
      # get_state e call sincrono: garante processamento de todos os casts anteriores
      state = CampaignMonitor.get_state(id)
      assert state.alert_count >= 1
      assert abs(state.last_z_score) > 3.0
    end
  end
end
