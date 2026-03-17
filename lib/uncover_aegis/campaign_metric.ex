defmodule UncoverAegis.CampaignMetric do
  @moduledoc """
  Schema Ecto para a tabela `campaign_metrics`.

  Representa uma linha de métrica de campanha de marketing digital,
  com os dados brutos do Meta/Google já sanitizados pelo pipeline
  do MVP 1 antes de serem persistidos.

  ## Campos

  - `campaign_id` — identificador externo (string) da campanha na plataforma.
  - `platform` — origem do dado: `"meta"`, `"google"`, `"tiktok"`, etc.
  - `spend` — gasto em moeda local (float). Campo central para z-score.
  - `impressions` — número de impressões veiculadas.
  - `clicks` — número de cliques registrados.
  - `conversions` — número de conversões (compras, leads, etc.).
  - `reported_at` — data/hora do relatório original (UTC).
  - `inserted_at` / `updated_at` — timestamps gerenciados pelo Ecto.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "campaign_metrics" do
    field :campaign_id, :string
    field :platform, :string
    field :spend, :float
    field :impressions, :integer
    field :clicks, :integer
    field :conversions, :integer
    field :reported_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields [:campaign_id, :platform, :spend, :reported_at]
  @optional_fields [:impressions, :clicks, :conversions]

  @doc """
  Valida e cria um changeset para inserção de uma métrica de campanha.

  ## Validações
  - Campos obrigatórios: `campaign_id`, `platform`, `spend`, `reported_at`.
  - `spend` deve ser >= 0 (gastos negativos são inválidos).
  - `platform` deve ser um dos valores conhecidos.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(metric \\ %__MODULE__{}, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:spend, greater_than_or_equal_to: 0.0)
    |> validate_inclusion(:platform, ["meta", "google", "tiktok", "linkedin", "twitter"])
  end
end
