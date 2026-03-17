defmodule UncoverAegis.InsightsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Testes de integração do módulo Insights: pipeline completo
  SQL guardrail (Rust) -> Ecto query (Elixir) -> Z-Score (Rust).

  Usa banco SQLite em memória (:memory:) configurado no config/test.exs.
  `async: false` porque compartilhamos o Repo (pool de conexões).
  """

  alias UncoverAegis.{Insights, Repo, CampaignMetric}
  import Ecto.Query

  # Roda a migração antes dos testes e limpa o banco após cada teste.
  setup do
    # Garante que a tabela existe no banco :memory:
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    # Seed: insere métricas de campanha para os testes consultarem
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    metrics = [
      %{campaign_id: "meta_001", platform: "meta", spend: 100.0,
        impressions: 10_000, clicks: 300, conversions: 15, reported_at: now},
      %{campaign_id: "meta_002", platform: "meta", spend: 105.0,
        impressions: 11_000, clicks: 320, conversions: 18, reported_at: now},
      %{campaign_id: "meta_003", platform: "meta", spend: 98.0,
        impressions: 9_800, clicks: 290, conversions: 14, reported_at: now},
      %{campaign_id: "goog_001", platform: "google", spend: 200.0,
        impressions: 25_000, clicks: 800, conversions: 40, reported_at: now}
    ]

    Enum.each(metrics, fn attrs ->
      %CampaignMetric{}
      |> CampaignMetric.changeset(attrs)
      |> Repo.insert!()
    end)

    :ok
  end

  describe "run_safe_query/1" do
    test "executa SELECT válido e retorna linhas" do
      sql = "SELECT campaign_id, spend FROM campaign_metrics WHERE platform = 'meta'"
      assert {:ok, result} = Insights.run_safe_query(sql)

      assert result.row_count == 3
      assert "campaign_id" in result.columns
      assert "spend" in result.columns
    end

    test "retorna metadados de z-score junto com as linhas" do
      sql = "SELECT spend FROM campaign_metrics ORDER BY spend"
      assert {:ok, result} = Insights.run_safe_query(sql)

      assert is_float(result.z_score)
      assert is_boolean(result.anomaly)
      assert result.anomaly_threshold == 3.0
    end

    test "detecta anomalia quando gasto é outlier" do
      # Insere uma métrica com gasto anomalo (10x a media)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %CampaignMetric{}
      |> CampaignMetric.changeset(%{
        campaign_id: "meta_anomaly",
        platform: "meta",
        spend: 9_999.0,
        reported_at: now
      })
      |> Repo.insert!()

      sql = "SELECT spend FROM campaign_metrics ORDER BY reported_at"
      assert {:ok, result} = Insights.run_safe_query(sql)

      assert result.anomaly == true
      assert result.z_score > 3.0
    end

    test "bloqueia DELETE gerado por LLM" do
      sql = "DELETE FROM campaign_metrics WHERE spend < 50"
      assert {:unsafe_sql, reason} = Insights.run_safe_query(sql)
      assert reason =~ "DELETE"
    end

    test "bloqueia DROP TABLE gerado por LLM" do
      assert {:unsafe_sql, _} = Insights.run_safe_query("DROP TABLE campaign_metrics")
    end

    test "bloqueia UPDATE gerado por LLM" do
      assert {:unsafe_sql, _} =
               Insights.run_safe_query("UPDATE campaign_metrics SET spend = 0 WHERE id = 1")
    end

    test "não há anomalia para gastos uniformes" do
      sql = "SELECT spend FROM campaign_metrics WHERE platform = 'meta'"
      assert {:ok, result} = Insights.run_safe_query(sql)

      # Meta: 100, 105, 98 — distribuição normal, sem anomalia
      assert result.anomaly == false
    end

    test "SELECT COUNT retorna row_count correto" do
      sql = "SELECT COUNT(*) as total FROM campaign_metrics"
      assert {:ok, result} = Insights.run_safe_query(sql)
      assert result.row_count == 1
    end
  end
end
