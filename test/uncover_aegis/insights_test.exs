defmodule UncoverAegis.InsightsTest do
  @moduledoc """
  Testes de integracao do pipeline Insights.

  Testa o fluxo completo: LLM Mock -> Guardrail Rust -> SQLite.
  Usa banco em memoria (`:memory:`) para isolamento entre testes.
  """
  use ExUnit.Case, async: false

  alias UncoverAegis.{Insights, Repo}

  # Insere dados minimos para os testes de query
  setup do
    # Garante banco limpo para cada teste
    Repo.query!("DELETE FROM campaign_metrics")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows = [
      %{campaign_id: "camp_a", platform: "google", spend: 1000.0,
        impressions: 10000, clicks: 500, conversions: 50,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now},
      %{campaign_id: "camp_b", platform: "meta", spend: 2000.0,
        impressions: 20000, clicks: 1000, conversions: 100,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now},
      %{campaign_id: "camp_c", platform: "google", spend: 1500.0,
        impressions: 15000, clicks: 750, conversions: 75,
        date: ~D[2026-03-11], inserted_at: now, updated_at: now},
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

    test "bloqueia DELETE e retorna :unsafe_sql" do
      assert {:unsafe_sql, reason} =
               Insights.run_safe_query("DELETE FROM campaign_metrics")

      assert is_binary(reason)
      # Confirma que nenhum dado foi apagado
      assert {:ok, %{rows: [[3]]}} =
               Insights.run_safe_query("SELECT COUNT(*) FROM campaign_metrics")
    end

    test "bloqueia DROP TABLE" do
      assert {:unsafe_sql, _} =
               Insights.run_safe_query("DROP TABLE campaign_metrics")
    end

    test "retorna lista vazia para query sem resultados" do
      sql = "SELECT * FROM campaign_metrics WHERE platform = 'tiktok'"
      assert {:ok, %{rows: []}} = Insights.run_safe_query(sql)
    end

    test "retorna erro para SQL invalido" do
      assert {:error, _reason} =
               Insights.run_safe_query("SELECT * FROM tabela_que_nao_existe")
    end
  end

  describe "ask/1 via LlmMock (perguntas reconhecidas)" do
    test "responde 'qual o gasto total?' com dados corretos" do
      assert {:ok, result} = Insights.ask("qual o gasto total?")
      assert result.rows != []
      # Total deve ser 4500.0 (1000 + 2000 + 1500)
      total = result.rows |> Enum.flat_map(& &1) |> Enum.filter(&is_number/1) |> Enum.sum()
      assert_in_delta total, 4500.0, 1.0
    end

    test "responde 'quantas campanhas temos?' com contagem correta" do
      assert {:ok, result} = Insights.ask("quantas campanhas temos?")
      assert [[count]] = result.rows
      assert count == 3
    end

    test "inclui metadados de observabilidade na resposta" do
      assert {:ok, result} = Insights.ask("quais plataformas usamos?")
      assert is_binary(result.metadata.sql)
      assert result.metadata.guardrail_us > 0
      assert result.metadata.query_ms >= 0
      assert result.row_count == length(result.rows)
    end

    test "inclui campo anomaly na resposta" do
      assert {:ok, result} = Insights.ask("qual o gasto total?")
      assert is_boolean(result.anomaly)
    end
  end

  describe "ask/1 — tratamento de erros" do
    test "retorna :llm error para pergunta nao reconhecida (sem Ollama)" do
      # Com Ollama indisponivel em CI, cai no LlmMock que nao reconhece
      result = Insights.ask("qual a umidade do ar hoje?")
      # Aceita tanto {:error, :llm, _} quanto {:ok, _} se Ollama estiver up
      assert match?({:error, :llm, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "anomalia Z-Score" do
    test "detecta anomalia quando ha outlier extremo de spend" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      # Insere valores normais + outlier extremo na mesma plataforma
      extra_rows = [
        %{campaign_id: "camp_x", platform: "linkedin", spend: 100.0,
          impressions: 1000, clicks: 50, conversions: 5,
          date: ~D[2026-03-10], inserted_at: now, updated_at: now},
        %{campaign_id: "camp_x", platform: "linkedin", spend: 102.0,
          impressions: 1000, clicks: 50, conversions: 5,
          date: ~D[2026-03-11], inserted_at: now, updated_at: now},
        %{campaign_id: "camp_x", platform: "linkedin", spend: 98.0,
          impressions: 1000, clicks: 50, conversions: 5,
          date: ~D[2026-03-12], inserted_at: now, updated_at: now},
        %{campaign_id: "camp_x", platform: "linkedin", spend: 99000.0,
          impressions: 1000, clicks: 50, conversions: 5,
          date: ~D[2026-03-13], inserted_at: now, updated_at: now},
      ]

      Repo.insert_all("campaign_metrics", extra_rows)

      # Query que retorna coluna 'spend' para ativar calculo de z-score
      sql = "SELECT spend FROM campaign_metrics WHERE platform = 'linkedin' ORDER BY spend"
      assert {:ok, result} = Insights.run_safe_query(sql)
      # Com outlier extremo, anomaly deve ser true
      assert result.anomaly == true
    end
  end
end
