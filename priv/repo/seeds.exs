# Seeds do Uncover Aegis — dados de campanhas para demonstracao do MVP4.
#
# Execucao: mix run priv/repo/seeds.exs
# (tambem chamado automaticamente por `mix ecto.setup`)

alias UncoverAegis.Repo

# Limpa dados anteriores para idempotencia
Repo.query!("DELETE FROM campaign_metrics")

now = DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

campaigns = [
  # Google — campanha saudavel
  {"camp_google_brand", "google", 1200.0, 4500, 180},
  {"camp_google_brand", "google", 1350.0, 4800, 210},
  {"camp_google_brand", "google", 1100.0, 4200, 175},
  {"camp_google_brand", "google", 1280.0, 4650, 195},
  {"camp_google_perf", "google", 3200.0, 12000, 520},
  {"camp_google_perf", "google", 3400.0, 13100, 580},
  {"camp_google_perf", "google", 3100.0, 11800, 500},

  # Meta — campanha com anomalia de gasto (Z-Score alto)
  {"camp_meta_retarg", "meta", 900.0, 6200, 310},
  {"camp_meta_retarg", "meta", 950.0, 6400, 325},
  {"camp_meta_retarg", "meta", 880.0, 6100, 298},
  {"camp_meta_retarg", "meta", 920.0, 6300, 315},
  {"camp_meta_retarg", "meta", 8500.0, 6350, 320},  # <- anomalia: gasto 9x a media
  {"camp_meta_brand", "meta", 2100.0, 9800, 420},
  {"camp_meta_brand", "meta", 2250.0, 10200, 445},
  {"camp_meta_brand", "meta", 2050.0, 9500, 410},

  # TikTok — engajamento alto, conversao baixa
  {"camp_tiktok_awareness", "tiktok", 1800.0, 35000, 140},
  {"camp_tiktok_awareness", "tiktok", 1950.0, 38000, 155},
  {"camp_tiktok_awareness", "tiktok", 1700.0, 33000, 130},
  {"camp_tiktok_promo", "tiktok", 2400.0, 42000, 210},
  {"camp_tiktok_promo", "tiktok", 2600.0, 45000, 225},

  # LinkedIn — alto CPC, alta conversao B2B
  {"camp_linkedin_leads", "linkedin", 4200.0, 1800, 380},
  {"camp_linkedin_leads", "linkedin", 4500.0, 1950, 410},
  {"camp_linkedin_leads", "linkedin", 4100.0, 1750, 365},
  {"camp_linkedin_brand", "linkedin", 2800.0, 1200, 245},
]

rows =
  Enum.map(campaigns, fn {campaign_id, platform, spend, clicks, conversions} ->
    %{
      campaign_id: campaign_id,
      platform: platform,
      spend: spend,
      clicks: clicks,
      conversions: conversions,
      recorded_at: now
    }
  end)

{count, _} = Repo.insert_all("campaign_metrics", rows)
IO.puts("[Seeds] #{count} registros inseridos em campaign_metrics.")
