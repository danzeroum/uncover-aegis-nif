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
  import Ecto.Query, warn: false

  alias UncoverAegis.Repo

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
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(metric \\ %__MODULE__{}, attrs) do
    metric
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:spend, greater_than_or_equal_to: 0.0)
    |> validate_inclusion(:platform, ["meta", "google", "tiktok", "linkedin", "twitter"])
  end

  @doc """
  Lista métricas com filtros opcionais de plataforma, período e limite.
  Usado pelo resolver GraphQL `campaigns`.
  """
  @spec list_metrics(map()) :: [%__MODULE__{}]
  def list_metrics(args \\ %{}) do
    query =
      from m in __MODULE__,
        order_by: [desc: m.reported_at]

    query
    |> maybe_filter_platform(args[:platform])
    |> maybe_filter_from(args[:from])
    |> maybe_filter_to(args[:to])
    |> limit(^Map.get(args, :limit, 50))
    |> Repo.all()
  end

  @doc """
  Retorna lista de valores de spend de uma campanha específica,
  ordenados por data. Usado pelo resolver GraphQL `adstock`.
  """
  @spec get_spends_by_campaign(String.t()) :: [float()]
  def get_spends_by_campaign(campaign_id) do
    from(m in __MODULE__,
      where: m.campaign_id == ^campaign_id,
      order_by: [asc: m.reported_at],
      select: m.spend
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Privado
  # ---------------------------------------------------------------------------

  defp maybe_filter_platform(query, nil), do: query
  defp maybe_filter_platform(query, platform) do
    where(query, [m], m.platform == ^platform)
  end

  defp maybe_filter_from(query, nil), do: query
  defp maybe_filter_from(query, from_str) do
    case Date.from_iso8601(from_str) do
      {:ok, date} ->
        dt = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
        where(query, [m], m.reported_at >= ^dt)
      _ -> query
    end
  end

  defp maybe_filter_to(query, nil), do: query
  defp maybe_filter_to(query, to_str) do
    case Date.from_iso8601(to_str) do
      {:ok, date} ->
        dt = DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
        where(query, [m], m.reported_at <= ^dt)
      _ -> query
    end
  end
end
