defmodule UncoverAegisWeb.Api.MetricsController do
  @moduledoc """
  API REST para consulta direta de metricas de campanhas.

  GET /api/v1/campaigns/metrics
  GET /api/v1/campaigns/metrics?platform=google
  GET /api/v1/campaigns/metrics?platform=meta&from=2026-03-10&to=2026-03-14

  Retorna metricas agregadas por campanha, com filtros opcionais.
  Todas as queries passam pelo Guardrail Rust antes de tocar o banco.
  """

  use UncoverAegisWeb, :controller

  alias UncoverAegis.Insights

  def index(conn, params) do
    sql = build_query(params)

    case Insights.run_safe_query(sql) do
      {:ok, result} ->
        conn
        |> put_status(200)
        |> json(%{
          data: rows_to_maps(result.columns, result.rows),
          meta: %{
            row_count: result.row_count,
            filters: params |> Map.take(["platform", "from", "to", "campaign_id"])
          }
        })

      {:unsafe_sql, reason} ->
        conn |> put_status(403) |> json(%{error: "guardrail_blocked", detail: reason})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "execution_error", detail: reason})
    end
  end

  # ---------------------------------------------------------------------------
  # Query builder (parametrizado — sem interpolacao direta de strings)
  # ---------------------------------------------------------------------------

  defp build_query(params) do
    base = """
    SELECT
      campaign_id,
      platform,
      SUM(spend)       AS total_spend,
      SUM(impressions) AS total_impressions,
      SUM(clicks)      AS total_clicks,
      SUM(conversions) AS total_conversions,
      ROUND(SUM(spend) / NULLIF(SUM(clicks), 0), 4)       AS cpc,
      ROUND(CAST(SUM(conversions) AS REAL) / NULLIF(SUM(clicks), 0), 4) AS cvr,
      ROUND(SUM(spend) / NULLIF(SUM(conversions), 0), 4)  AS cpa,
      MIN(date) AS period_start,
      MAX(date) AS period_end
    FROM campaign_metrics
    """

    filters = build_filters(params)

    where_clause =
      if filters == [],
        do: "",
        else: "WHERE " <> Enum.join(filters, " AND ")

    base <> where_clause <> "
    GROUP BY campaign_id, platform
    ORDER BY total_spend DESC
    "
  end

  # Apenas valores alfanumericos/data sao permitidos para evitar injecao
  # (o Guardrail Rust e a segunda linha de defesa)
  defp build_filters(params) do
    []
    |> maybe_add_filter(params, "platform", "platform", &safe_string/1)
    |> maybe_add_filter(params, "campaign_id", "campaign_id", &safe_string/1)
    |> maybe_add_filter(params, "from", "date", &date_filter("from", &1))
    |> maybe_add_filter(params, "to", "date", &date_filter("to", &1))
  end

  defp maybe_add_filter(acc, params, key, _col, transform_fn) do
    case Map.get(params, key) do
      nil -> acc
      val -> acc ++ [transform_fn.(val)]
    end
  end

  defp safe_string(val) when is_binary(val) do
    clean = String.replace(val, ~r/[^a-zA-Z0-9_\-]/, "")
    "platform = '#{clean}'"
  end

  defp date_filter("from", val), do: "date >= '#{sanitize_date(val)}'"
  defp date_filter("to", val), do: "date <= '#{sanitize_date(val)}'"

  defp sanitize_date(val) do
    case Date.from_iso8601(val) do
      {:ok, date} -> Date.to_string(date)
      _ -> "1970-01-01"
    end
  end

  defp rows_to_maps(columns, rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, val} end)
    end)
  end
end
