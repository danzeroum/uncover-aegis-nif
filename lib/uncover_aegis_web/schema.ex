defmodule UncoverAegisWeb.Schema do
  @moduledoc """
  Schema GraphQL (Absinthe) do Uncover Aegis.

  ## Endpoints disponíveis

  - `POST /api/graphql`  — queries e mutations
  - `GET  /graphiql`     — Playground interativo (apenas dev)

  ## Queries

  - `campaigns(platform, from, to, limit)` — lista métricas com filtros
  - `insight(question | sql)` — pipeline NL→SQL completo (com cache Redis)
  - `adstock(campaign_id, decay, alpha)` — MMM interativo via NIF Rust
  - `health` — health check via GraphQL

  ## Subscriptions

  - `sentinel_alerts(campaign_id?)` — alertas Z-Score em tempo real via WebSocket
  """

  use Absinthe.Schema

  alias UncoverAegis.{Insights, Native, CampaignMetric}

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @desc "Métricas agregadas de uma campanha de mídia"
  object :campaign_metric do
    field(:campaign_id, :string, description: "ID único da campanha")
    field(:platform, :string, description: "google | meta | tiktok | linkedin")
    field(:total_spend, :float, description: "Gasto total no período (R$)")
    field(:total_impressions, :integer)
    field(:total_clicks, :integer)
    field(:total_conversions, :integer)
    field(:cpc, :float, description: "Custo por Clique = spend/clicks")
    field(:cpa, :float, description: "Custo por Aquisição = spend/conversions")
    field(:cvr, :float, description: "Taxa de Conversão = conversions/clicks")
    field(:period_start, :string)
    field(:period_end, :string)
  end

  @desc "Resultado do pipeline NL→SQL com metadados completos"
  object :insight_result do
    field(:row_count, :integer)
    field(:sql, :string, description: "SQL gerado e validado pelo Guardrail Rust")
    field(:guardrail_us, :integer, description: "Latência do NIF Rust em µs")
    field(:query_ms, :integer, description: "Latência da query SQLite em ms")
    field(:cache_hit, :boolean, description: "Resultado veio do cache Redis?")
    field(:anomaly, :anomaly_info)
    field(:z_score, :float)
  end

  @desc "Detecção de anomalia Z-Score via NIF Rust"
  object :anomaly_info do
    field(:detected, :boolean)
    field(:z_score, :float)
  end

  @desc "Resultado do modelo Adstock MMM via NIF Rust calculate_adstock/4"
  object :adstock_result do
    field(:campaign_id, :string)
    field(:decay, :float, description: "Carry-over entre períodos (0.0–1.0)")
    field(:alpha, :float, description: "Curvatura Hill de saturação")
    field(:half_sat, :float, description: "K: spend no ponto de 50% de saturação")
    field(:adstock_values, list_of(:float), description: "Impacto acumulado por período")
    field(:saturated_values, list_of(:float), description: "Saturação 0.0–1.0 por período")
    field(:contribution_pct, list_of(:float), description: "% de contribuição por período")
  end

  @desc "Alerta de anomalia de spend detectado pelo Sentinel"
  object :sentinel_alert do
    field(:campaign_id, :string)
    field(:z_score, :float)
    field(:spend, :float)
    field(:severity, :string, description: "critical (|Z|≥4) ou warning (3≤|Z|<4)")
    field(:timestamp, :string)
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  query do
    @desc "Lista métricas de campanhas com filtros opcionais"
    field :campaigns, list_of(:campaign_metric) do
      arg(:platform, :string, description: "Filtrar por plataforma")
      arg(:from, :string, description: "Data início YYYY-MM-DD")
      arg(:to, :string, description: "Data fim YYYY-MM-DD")
      arg(:limit, :integer, default_value: 50)

      resolve(fn args, _ ->
        {:ok, CampaignMetric.list_metrics(args)}
      end)
    end

    @desc "Executa pergunta em linguagem natural ou SQL direto no pipeline completo"
    field :insight, :insight_result do
      arg(:question, :string, description: "Pergunta em linguagem natural")
      arg(:sql, :string, description: "SQL direto (passa pelo Guardrail Rust)")

      resolve(fn
        %{question: q}, _ when is_binary(q) ->
          case Insights.ask(q) do
            {:ok, result} ->
              {:ok,
               %{
                 row_count: result.row_count,
                 sql: get_in(result, [:metadata, :sql]),
                 guardrail_us: get_in(result, [:metadata, :guardrail_us]),
                 query_ms: get_in(result, [:metadata, :query_ms]),
                 cache_hit: Map.get(result, :cache_hit, false),
                 z_score: result.z_score,
                 anomaly: %{detected: result.anomaly, z_score: result.z_score}
               }}

            {:error, _, reason} ->
              {:error, reason}
          end

        %{sql: sql}, _ when is_binary(sql) ->
          case Insights.run_safe_query(sql) do
            {:ok, result} ->
              {:ok,
               %{
                 row_count: result.row_count,
                 sql: sql,
                 z_score: result.z_score,
                 anomaly: %{detected: result.anomaly, z_score: result.z_score}
               }}

            {:unsafe_sql, reason} ->
              {:error, "Guardrail bloqueou: #{reason}"}

            {:error, reason} ->
              {:error, reason}
          end

        _, _ ->
          {:error, "Forneça 'question' (linguagem natural) ou 'sql' (SQL direto)"}
      end)
    end

    @desc "Calcula modelo Adstock MMM para uma campanha via NIF Rust"
    field :adstock, :adstock_result do
      arg(:campaign_id, non_null(:string))
      arg(:decay, :float, default_value: 0.7, description: "Carry-over (0.0–1.0)")
      arg(:alpha, :float, default_value: 2.0, description: "Hill α: curvatura saturação")

      resolve(fn %{campaign_id: id} = args, _ ->
        spends = CampaignMetric.get_spends_by_campaign(id)

        if Enum.empty?(spends) do
          {:error, "Campanha '#{id}' não encontrada ou sem dados de spend"}
        else
          half_sat = Enum.sum(spends) / length(spends)

          case Native.calculate_adstock(spends, args[:decay], args[:alpha], half_sat) do
            {:ok, result} ->
              {:ok,
               Map.merge(result, %{
                 campaign_id: id,
                 decay: args[:decay],
                 alpha: args[:alpha],
                 half_sat: half_sat
               })}

            {:error, reason} ->
              {:error, "Erro no NIF Rust: #{reason}"}
          end
        end
      end)
    end

    @desc "Health check via GraphQL"
    field :health, :string do
      resolve(fn _, _ -> {:ok, "ok — uncover-aegis v0.4.0"} end)
    end
  end

  # ---------------------------------------------------------------------------
  # Subscriptions — alertas Sentinel em tempo real via WebSocket
  # ---------------------------------------------------------------------------

  subscription do
    @desc """
    Recebe alertas de anomalia Z-Score do Sentinel em tempo real.
    Filtre por `campaign_id` para monitorar uma campanha específica,
    ou omita para receber todos os alertas.
    """
    field :sentinel_alerts, :sentinel_alert do
      arg(:campaign_id, :string, description: "Filtrar por campanha (opcional)")

      config(fn args, _ ->
        topic =
          case args do
            %{campaign_id: id} when is_binary(id) and id != "" -> "sentinel:" <> id
            _ -> "sentinel:all"
          end

        {:ok, topic: topic}
      end)

      trigger(:sentinel_alerts,
        topic: fn alert ->
          ["sentinel:" <> alert.campaign_id, "sentinel:all"]
        end
      )
    end
  end
end
