defmodule UncoverAegis.Repo.Migrations.CreateCampaignMetrics do
  use Ecto.Migration

  @moduledoc """
  Cria a tabela `campaign_metrics` que armazena dados de performance
  de campanhas de marketing (Meta Ads, Google Ads, etc.).

  Esta tabela serve como fonte de dados para as consultas Text-to-SQL
  do contexto de Insights (MVP 2).
  """

  def change do
    create table(:campaign_metrics) do
      add :campaign_id, :string, null: false, comment: "Identificador unico da campanha"
      add :platform, :string, null: false, default: "unknown", comment: "Meta | Google | TikTok"
      add :spend, :float, null: false, comment: "Gasto em reais (R$)"
      add :impressions, :integer, null: false, comment: "Total de impressoes"
      add :clicks, :integer, null: false, default: 0, comment: "Total de cliques"
      add :conversions, :integer, null: false, default: 0, comment: "Total de conversoes"
      add :date, :date, null: false, comment: "Data do registro (YYYY-MM-DD)"

      timestamps()
    end

    # Indices para otimizar as queries mais comuns
    create index(:campaign_metrics, [:campaign_id])
    create index(:campaign_metrics, [:date])
    create index(:campaign_metrics, [:platform])
    create unique_index(:campaign_metrics, [:campaign_id, :date, :platform],
      name: :uq_campaign_date_platform
    )
  end
end
