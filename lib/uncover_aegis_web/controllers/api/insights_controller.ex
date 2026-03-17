defmodule UncoverAegisWeb.Api.InsightsController do
  @moduledoc """
  API REST para o pipeline de insights conversacional.

  POST /api/v1/insights/query

  Aceita uma pergunta em linguagem natural ou SQL direto,
  processa pelo pipeline completo (LLM -> Guardrail Rust -> Ecto)
  e retorna o resultado estruturado com metadados de observabilidade.

  ## Request (NL)

      POST /api/v1/insights/query
      Content-Type: application/json

      { "question": "qual o gasto total por plataforma?" }

  ## Request (SQL direto)

      { "sql": "SELECT platform, SUM(spend) FROM campaign_metrics GROUP BY platform" }

  ## Response

      {
        "data": [
          {"platform": "meta", "total_spend": 18550.0},
          {"platform": "google", "total_spend": 14630.0}
        ],
        "metadata": {
          "sql": "SELECT ...",
          "guardrail_us": 4521,
          "query_ms": 3,
          "row_count": 4
        }
      }
  """

  use UncoverAegisWeb, :controller

  alias UncoverAegis.Insights

  def query(conn, %{"question" => question}) when is_binary(question) do
    case Insights.ask(question) do
      {:ok, result} ->
        conn
        |> put_status(200)
        |> json(%{
          data: rows_to_maps(result.columns, result.rows),
          metadata: %{
            sql: result.metadata.sql,
            guardrail_us: result.metadata.guardrail_us,
            query_ms: result.metadata.query_ms,
            row_count: result.row_count
          },
          anomaly: %{
            detected: result.anomaly,
            z_score: result.z_score
          }
        })

      {:error, :llm, reason} ->
        conn |> put_status(422) |> json(%{error: "llm_error", detail: reason})

      {:error, :guardrail, reason} ->
        conn |> put_status(403) |> json(%{error: "guardrail_blocked", detail: reason})

      {:error, :database, reason} ->
        conn |> put_status(500) |> json(%{error: "database_error", detail: reason})
    end
  end

  def query(conn, %{"sql" => sql}) when is_binary(sql) do
    case Insights.run_safe_query(sql) do
      {:ok, result} ->
        conn
        |> put_status(200)
        |> json(%{
          data: rows_to_maps(result.columns, result.rows),
          metadata: %{row_count: result.row_count}
        })

      {:unsafe_sql, reason} ->
        conn |> put_status(403) |> json(%{error: "guardrail_blocked", detail: reason})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "execution_error", detail: reason})
    end
  end

  def query(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{
      error: "bad_request",
      detail: "Forneça 'question' (linguagem natural) ou 'sql' (query direta)"
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp rows_to_maps(columns, rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, val} end)
    end)
  end
end
