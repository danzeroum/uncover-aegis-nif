# Seeds do Uncover Aegis — dados de campanhas para demonstracao do MVP4.
#
# Execucao: mix run priv/repo/seeds.exs

alias UncoverAegis.Repo

Repo.query!("DELETE FROM campaign_metrics")

now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

# {campaign_id, platform, date, spend, impressions, clicks, conversions}
campaigns = [
  # Google — campanha saudavel
  {"camp_google_brand", "google", ~D[2026-03-10], 1200.0, 45000, 4500, 180},
  {"camp_google_brand", "google", ~D[2026-03-11], 1350.0, 48000, 4800, 210},
  {"camp_google_brand", "google", ~D[2026-03-12], 1100.0, 42000, 4200, 175},
  {"camp_google_brand", "google", ~D[2026-03-13], 1280.0, 46500, 4650, 195},
  {"camp_google_perf",  "google", ~D[2026-03-10], 3200.0, 120000, 12000, 520},
  {"camp_google_perf",  "google", ~D[2026-03-11], 3400.0, 131000, 13100, 580},
  {"camp_google_perf",  "google", ~D[2026-03-12], 3100.0, 118000, 11800, 500},

  # Meta — campanha com anomalia de gasto (Z-Score alto)
  {"camp_meta_retarg", "meta", ~D[2026-03-10], 900.0,  62000, 6200, 310},
  {"camp_meta_retarg", "meta", ~D[2026-03-11], 950.0,  64000, 6400, 325},
  {"camp_meta_retarg", "meta", ~D[2026-03-12], 880.0,  61000, 6100, 298},
  {"camp_meta_retarg", "meta", ~D[2026-03-13], 920.0,  63000, 6300, 315},
  # Anomalia: gasto 9x a media historica da campanha
  {"camp_meta_retarg", "meta", ~D[2026-03-14], 8500.0, 63500, 6350, 320},
  {"camp_meta_brand",  "meta", ~D[2026-03-10], 2100.0, 98000, 9800, 420},
  {"camp_meta_brand",  "meta", ~D[2026-03-11], 2250.0, 102000, 10200, 445},
  {"camp_meta_brand",  "meta", ~D[2026-03-12], 2050.0, 95000, 9500, 410},

  # TikTok — alto alcance, conversao baixa
  {"camp_tiktok_awareness", "tiktok", ~D[2026-03-10], 1800.0, 350000, 35000, 140},
  {"camp_tiktok_awareness", "tiktok", ~D[2026-03-11], 1950.0, 380000, 38000, 155},
  {"camp_tiktok_awareness", "tiktok", ~D[2026-03-12], 1700.0, 330000, 33000, 130},
  {"camp_tiktok_promo",     "tiktok", ~D[2026-03-10], 2400.0, 420000, 42000, 210},
  {"camp_tiktok_promo",     "tiktok", ~D[2026-03-11], 2600.0, 450000, 45000, 225},

  # LinkedIn — alto CPC, alta conversao B2B
  {"camp_linkedin_leads", "linkedin", ~D[2026-03-10], 4200.0, 18000, 1800, 380},
  {"camp_linkedin_leads", "linkedin", ~D[2026-03-11], 4500.0, 19500, 1950, 410},
  {"camp_linkedin_leads", "linkedin", ~D[2026-03-12], 4100.0, 17500, 1750, 365},
  {"camp_linkedin_brand", "linkedin", ~D[2026-03-10], 2800.0, 12000, 1200, 245},
]

rows =
  Enum.map(campaigns, fn {campaign_id, platform, date, spend, impressions, clicks, conversions} ->
    %{
      campaign_id: campaign_id,
      platform: platform,
      date: date,
      spend: spend,
      impressions: impressions,
      clicks: clicks,
      conversions: conversions,
      inserted_at: now,
      updated_at: now
    }
  end)

{count, _} = Repo.insert_all("campaign_metrics", rows)
IO.puts("[Seeds] #{count} registros inseridos em campaign_metrics.")
