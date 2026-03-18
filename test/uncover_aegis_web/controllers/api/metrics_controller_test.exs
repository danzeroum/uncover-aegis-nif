defmodule UncoverAegisWeb.Api.MetricsControllerTest do
  @moduledoc """
  Testes de contrato do endpoint GET /api/v1/campaigns/metrics.

  Verifica estrutura da resposta, filtros por plataforma e
  presenca dos KPIs de MarTech (cpc, cvr, cpa).
  """
  use UncoverAegisWeb.ConnCase, async: false

  alias UncoverAegis.Repo

  setup do
    Repo.query!("DELETE FROM campaign_metrics")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("campaign_metrics", [
      %{
        campaign_id: "camp_google", platform: "google", spend: 1200.0,
        impressions: 45_000, clicks: 4_500, conversions: 180,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now
      },
      %{
        campaign_id: "camp_google", platform: "google", spend: 1350.0,
        impressions: 48_000, clicks: 4_800, conversions: 210,
        date: ~D[2026-03-11], inserted_at: now, updated_at: now
      },
      %{
        campaign_id: "camp_meta", platform: "meta", spend: 2100.0,
        impressions: 85_000, clicks: 3_400, conversions: 95,
        date: ~D[2026-03-10], inserted_at: now, updated_at: now
      }
    ])
    :ok
  end

  describe "GET /api/v1/campaigns/metrics" do
    test "retorna todas as campanhas sem filtro", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics")
      assert conn.status == 200
      body = json_response(conn, 200)
      assert length(body["data"]) == 2
    end

    test "filtra por plataforma google", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics?platform=google")
      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["platform"] == "google"
    end

    test "filtra por plataforma meta", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics?platform=meta")
      body = json_response(conn, 200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["platform"] == "meta"
    end

    test "plataforma inexistente retorna lista vazia", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics?platform=snapchat")
      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "resposta contem KPIs cpc, cvr e cpa numericos", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics?platform=google")
      body = json_response(conn, 200)
      campaign = hd(body["data"])
      assert is_number(campaign["cpc"])
      assert is_number(campaign["cvr"])
      assert is_number(campaign["cpa"])
      # CPC = 2550 / 9300 ~= 0.27
      assert campaign["cpc"] > 0
      assert campaign["cpa"] > 0
    end

    test "resposta contem campo meta com row_count", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics")
      body = json_response(conn, 200)
      assert body["meta"]["row_count"] == 2
    end

    test "header x-request-id esta presente", %{conn: conn} do
      conn = get(conn, "/api/v1/campaigns/metrics")
      assert get_resp_header(conn, "x-request-id") != []
    end
  end
end
