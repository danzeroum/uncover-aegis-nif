defmodule UncoverAegisWeb.Api.InsightsControllerTest do
  @moduledoc """
  Testes de contrato do endpoint POST /api/v1/insights/query.
  """
  use UncoverAegisWeb.ConnCase, async: false

  alias UncoverAegis.Repo

  setup do
    Repo.query!("DELETE FROM campaign_metrics")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("campaign_metrics", [
      %{
        campaign_id: "camp_a", platform: "google", spend: 1000.0,
        impressions: 10_000, clicks: 500, conversions: 50,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now
      },
      %{
        campaign_id: "camp_b", platform: "meta", spend: 2000.0,
        impressions: 20_000, clicks: 1_000, conversions: 100,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now
      }
    ])
    :ok
  end

  describe "POST /api/v1/insights/query com SQL direto" do
    test "SQL SELECT valido retorna HTTP 200 com data", %{conn: conn} do
      conn =
        post(conn, "/api/v1/insights/query", %{
          "sql" => "SELECT platform, SUM(spend) AS total FROM campaign_metrics GROUP BY platform"
        })

      assert conn.status == 200
      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert length(body["data"]) == 2
    end

    test "DELETE retorna HTTP 403 guardrail_blocked", %{conn: conn} do
      conn =
        post(conn, "/api/v1/insights/query", %{
          "sql" => "DELETE FROM campaign_metrics"
        })

      assert conn.status == 403
      body = json_response(conn, 403)
      assert body["error"] == "guardrail_blocked"
      assert is_binary(body["detail"])
    end

    test "DROP TABLE retorna HTTP 403", %{conn: conn} do
      conn =
        post(conn, "/api/v1/insights/query", %{
          "sql" => "DROP TABLE campaign_metrics"
        })

      assert conn.status == 403
    end

    test "body vazio retorna HTTP 400 (bad_request)", %{conn: conn} do
      # Controller retorna 400 quando nao ha 'question' nem 'sql'
      conn = post(conn, "/api/v1/insights/query", %{})
      assert conn.status == 400
      body = json_response(conn, 400)
      assert body["error"] == "bad_request"
    end

    test "SQL direto retorna campo metadata com row_count", %{conn: conn} do
      # SQL direto nao passa pelo LLM, entao nao ha guardrail_us no metadata
      # O contrato do run_safe_query retorna apenas row_count
      conn =
        post(conn, "/api/v1/insights/query", %{
          "sql" => "SELECT COUNT(*) AS n FROM campaign_metrics"
        })

      body = json_response(conn, 200)
      assert is_map(body["metadata"])
      assert is_number(body["metadata"]["row_count"])
    end

    test "header x-request-id esta presente", %{conn: conn} do
      conn =
        post(conn, "/api/v1/insights/query", %{
          "sql" => "SELECT 1"
        })

      assert get_resp_header(conn, "x-request-id") != []
    end
  end

  describe "POST /api/v1/insights/query com pergunta NL (LlmMock)" do
    test "pergunta reconhecida retorna HTTP 200 com data", %{conn: conn} do
      conn =
        post(conn, "/api/v1/insights/query", %{
          "question" => "qual o gasto total?"
        })

      assert conn.status == 200
      body = json_response(conn, 200)
      assert is_list(body["data"])
    end

    test "resposta NL contem campo anomaly com chave detected", %{conn: conn} do
      # O controller retorna anomaly como objeto: %{detected: bool, z_score: float}
      conn =
        post(conn, "/api/v1/insights/query", %{
          "question" => "qual o gasto total?"
        })

      body = json_response(conn, 200)
      assert is_map(body["anomaly"])
      assert is_boolean(body["anomaly"]["detected"])
      assert is_number(body["anomaly"]["z_score"])
    end

    test "resposta NL contem metadata com guardrail_us", %{conn: conn} do
      conn =
        post(conn, "/api/v1/insights/query", %{
          "question" => "qual o gasto total?"
        })

      body = json_response(conn, 200)
      assert is_number(body["metadata"]["guardrail_us"])
      assert body["metadata"]["guardrail_us"] > 0
    end
  end
end
