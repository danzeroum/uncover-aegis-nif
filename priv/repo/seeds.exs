# Seeds com dados realistas de MarTech
# Plataformas: Google, Meta, TikTok, LinkedIn
# Verticais: Varejo, Telecom, Financeiro, Educacao
# KPIs: spend, impressions, clicks, conversions -> CPC, CVR, CPA calculados na API

alias UncoverAegis.Repo

Repo.query!("DELETE FROM campaign_metrics")

now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

records = [
  # ---- Google Brand (Varejo) ----
  %{date: ~D[2026-03-10], campaign_id: "camp_google_brand",    platform: "google",   spend: 1200.0,  impressions: 45_000,  clicks: 4_500,  conversions: 180},
  %{date: ~D[2026-03-11], campaign_id: "camp_google_brand",    platform: "google",   spend: 1350.0,  impressions: 48_000,  clicks: 4_800,  conversions: 210},
  %{date: ~D[2026-03-12], campaign_id: "camp_google_brand",    platform: "google",   spend: 1100.0,  impressions: 42_000,  clicks: 4_200,  conversions: 175},
  %{date: ~D[2026-03-13], campaign_id: "camp_google_brand",    platform: "google",   spend: 1280.0,  impressions: 46_500,  clicks: 4_650,  conversions: 195},

  # ---- Google Performance Max (Telecom) ----
  %{date: ~D[2026-03-10], campaign_id: "camp_google_perfmax",  platform: "google",   spend: 3200.0,  impressions: 120_000, clicks: 12_000, conversions: 520},
  %{date: ~D[2026-03-11], campaign_id: "camp_google_perfmax",  platform: "google",   spend: 3400.0,  impressions: 131_000, clicks: 13_100, conversions: 560},
  %{date: ~D[2026-03-12], campaign_id: "camp_google_perfmax",  platform: "google",   spend: 2950.0,  impressions: 115_000, clicks: 11_500, conversions: 490},
  %{date: ~D[2026-03-13], campaign_id: "camp_google_perfmax",  platform: "google",   spend: 3100.0,  impressions: 118_000, clicks: 11_800, conversions: 505},

  # ---- Meta Awareness (Financeiro) ----
  %{date: ~D[2026-03-10], campaign_id: "camp_meta_awareness",  platform: "meta",     spend: 2100.0,  impressions: 85_000,  clicks: 3_400,  conversions: 95},
  %{date: ~D[2026-03-11], campaign_id: "camp_meta_awareness",  platform: "meta",     spend: 2300.0,  impressions: 91_000,  clicks: 3_640,  conversions: 102},
  %{date: ~D[2026-03-12], campaign_id: "camp_meta_awareness",  platform: "meta",     spend: 1980.0,  impressions: 79_000,  clicks: 3_160,  conversions: 88},
  %{date: ~D[2026-03-13], campaign_id: "camp_meta_awareness",  platform: "meta",     spend: 2050.0,  impressions: 82_000,  clicks: 3_280,  conversions: 91},

  # ---- Meta Retargeting (Varejo) ----
  %{date: ~D[2026-03-10], campaign_id: "camp_meta_retarg",     platform: "meta",     spend: 1500.0,  impressions: 40_000,  clicks: 6_000,  conversions: 320},
  %{date: ~D[2026-03-11], campaign_id: "camp_meta_retarg",     platform: "meta",     spend: 1620.0,  impressions: 43_000,  clicks: 6_450,  conversions: 345},
  %{date: ~D[2026-03-12], campaign_id: "camp_meta_retarg",     platform: "meta",     spend: 1450.0,  impressions: 38_500,  clicks: 5_775,  conversions: 308},
  %{date: ~D[2026-03-13], campaign_id: "camp_meta_retarg",     platform: "meta",     spend: 1580.0,  impressions: 41_000,  clicks: 6_150,  conversions: 328},

  # ---- TikTok Awareness (Educacao) ----
  %{date: ~D[2026-03-10], campaign_id: "camp_tiktok_awareness", platform: "tiktok",  spend: 800.0,   impressions: 200_000, clicks: 8_000,  conversions: 120},
  %{date: ~D[2026-03-11], campaign_id: "camp_tiktok_awareness", platform: "tiktok",  spend: 920.0,   impressions: 230_000, clicks: 9_200,  conversions: 138},
  %{date: ~D[2026-03-12], campaign_id: "camp_tiktok_awareness", platform: "tiktok",  spend: 750.0,   impressions: 187_500, clicks: 7_500,  conversions: 112},
  %{date: ~D[2026-03-13], campaign_id: "camp_tiktok_awareness", platform: "tiktok",  spend: 870.0,   impressions: 217_500, clicks: 8_700,  conversions: 130},

  # ---- LinkedIn B2B (Financeiro) ----
  %{date: ~D[2026-03-10], campaign_id: "camp_linkedin_b2b",    platform: "linkedin", spend: 4200.0,  impressions: 18_000,  clicks: 720,    conversions: 28},
  %{date: ~D[2026-03-11], campaign_id: "camp_linkedin_b2b",    platform: "linkedin", spend: 4500.0,  impressions: 19_500,  clicks: 780,    conversions: 31},
  %{date: ~D[2026-03-12], campaign_id: "camp_linkedin_b2b",    platform: "linkedin", spend: 3900.0,  impressions: 16_800,  clicks: 672,    conversions: 26},
  %{date: ~D[2026-03-13], campaign_id: "camp_linkedin_b2b",    platform: "linkedin", spend: 4100.0,  impressions: 17_600,  clicks: 704,    conversions: 28},
]

rows =
  Enum.map(records, fn r ->
    Map.merge(r, %{inserted_at: now, updated_at: now})
  end)

{count, _} = Repo.insert_all("campaign_metrics", rows)
IO.puts("[Seeds] #{count} registros inseridos em campaign_metrics.")
IO.puts("""
[Seeds] Dados realistas de MarTech:
  - 6 campanhas: Google Brand, Google PMax, Meta Awareness, Meta Retargeting, TikTok, LinkedIn B2B
  - 4 plataformas: google, meta, tiktok, linkedin
  - Verticais: Varejo, Telecom, Financeiro, Educacao
  - KPIs calculáveis: CPC, CVR, CPA, CTR

Exemplos de consulta:
  curl 'http://localhost:4000/api/v1/campaigns/metrics?platform=meta'
  curl -X POST http://localhost:4000/api/v1/insights/query -d '{"question": "qual plataforma tem melhor CPA?"}'
""")
