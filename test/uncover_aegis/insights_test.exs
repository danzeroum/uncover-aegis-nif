defmodule UncoverAegis.InsightsTest do
  @moduledoc """
  Testes de integracao do pipeline Insights.

  Testa o fluxo: LlmMock -> Guardrail Rust -> SQLite.
  Cada teste limpa os dados no setup para garantir isolamento.
  """
  use ExUnit.Case, async: false

  alias UncoverAegis.{Insights, Repo}

  setup do
    Repo.query!("DELETE FROM campaign_metrics")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows = [
      %{
        campaign_id: "camp_a", platform: "google", spend: 1000.0,
        impressions: 10_000, clicks: 500, conversions: 50,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now
      },
      %{
        campaign_id: "camp_b", platform: "meta", spend: 2000.0,
        impressions: 20_000, clicks: 1_000, conversions: 100,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now
      },
      %{
        campaign_id: "camp_c", platform: "google", spend: 1500.0,
        impressions: 15_000, clicks: 750, conversions: 75,
        date: ~D[2026-03-11], inserted_at: now, updated_at: now
      },
    ]

    Repo.insert_all("campaign_metrics", rows)
    :ok
  end

  describe "run_safe_query/1" do
    test "executa SELECT valido e retorna linhas" do
      sql = "SELECT platform, SUM(spend) AS total FROM campaign_metrics GROUP BY platform ORDER BY total DESC"
      assert {:ok, result} = Insights.run_safe_query(sql)
      assert length(result.rows) == 2
      assert result.columns == ["platform", "total"]
    end

    test "bloqueia DELETE e confirma que dados nao foram apagados" do
      assert {:unsafe_sql, reason} = Insights.run_safe_query("DELETE FROM campaign_metrics")
      assert is_binary(reason)

      assert {:ok, count_result} = Insights.run_safe_query("SELECT COUNT(*) FROM campaign_metrics")
      assert [[3]] = count_result.rows
    end

    test "bloqueia DROP TABLE" do
      assert {:unsafe_sql, _} = Insights.run_safe_query("DROP TABLE campaign_metrics")
    end

    test "retorna lista vazia para query sem resultados" do
      sql = "SELECT * FROM campaign_metrics WHERE platform = 'tiktok'"
      assert {:ok, %{rows: []}} = Insights.run_safe_query(sql)
    end

    test "retorna erro para SQL invalido (tabela inexistente)" do
      assert {:error, _reason} = Insights.run_safe_query("SELECT * FROM tabela_fantasma")
    end
  end

  describe "ask/1 via LlmMock" do
    test "responde 'qual o gasto total?' e retorna valor numerico" do
      assert {:ok, result} = Insights.ask("qual o gasto total?")
      assert result.rows != []
      total =
        result.rows
        |> List.flatten()
        |> Enum.filter(&is_number/1)
        |> Enum.sum()
      assert_in_delta total, 4500.0, 1.0
    end

    test "inclui metadados de observabilidade" do
      assert {:ok, result} = Insights.ask("qual o gasto total?")
      assert is_binary(result.metadata.sql)
      assert result.metadata.guardrail_us > 0
      assert result.metadata.query_ms >= 0
      assert result.row_count == length(result.rows)
    end

    test "inclui campo anomaly booleano" do
      assert {:ok, result} = Insights.ask("qual o gasto total?")
      assert is_boolean(result.anomaly)
    end
  end

  describe "anomalia Z-Score via Insights.run_safe_query" do
    test "resultado inclui campo anomaly" do
      sql = "SELECT spend FROM campaign_metrics ORDER BY spend"
      assert {:ok, result} = Insights.run_safe_query(sql)
      # Com 3 valores uniformes (1000, 1500, 2000), nao ha anomalia forte
      assert is_boolean(result.anomaly)
    end

    test "retorna row_count correto" do
      sql = "SELECT * FROM campaign_metrics"
      assert {:ok, result} = Insights.run_safe_query(sql)
      assert result.row_count == 3
    end
  end
end
