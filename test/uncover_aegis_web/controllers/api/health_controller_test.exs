defmodule UncoverAegisWeb.Api.HealthControllerTest do
  @moduledoc """
  Testes de contrato do endpoint GET /api/health.

  Verifica estrutura da resposta e presenca dos campos obrigatorios.
  Nao mocka subsistemas: testa o comportamento real em ambiente de teste.
  """
  use UncoverAegisWeb.ConnCase, async: false

  describe "GET /api/health" do
    test "retorna HTTP 200 com status ok", %{conn: conn} do
      conn = get(conn, "/api/health")
      assert conn.status == 200
      body = json_response(conn, 200)
      assert body["status"] == "ok"
    end

    test "resposta contem campo version", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)
      assert is_binary(body["version"])
      assert body["version"] != ""
    end

    test "resposta contem campo timestamp ISO 8601", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)
      assert {:ok, _, _} = DateTime.from_iso8601(body["timestamp"])
    end

    test "checks contem subsistemas database e guardrail_rust", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)
      checks = body["checks"]
      assert is_map(checks["database"])
      assert is_map(checks["guardrail_rust"])
      assert checks["database"]["status"] == "ok"
      assert checks["guardrail_rust"]["status"] == "ok"
    end

    test "database check contem latency_ms numerico", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)
      assert is_number(body["checks"]["database"]["latency_ms"])
    end

    test "guardrail check contem latency_us numerico", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)
      assert is_number(body["checks"]["guardrail_rust"]["latency_us"])
    end

    test "header x-request-id esta presente na resposta", %{conn: conn} do
      conn = get(conn, "/api/health")
      assert get_resp_header(conn, "x-request-id") != []
    end
  end
end
