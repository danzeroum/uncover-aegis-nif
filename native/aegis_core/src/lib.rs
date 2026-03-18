//! aegis_core — Núcleo de sanitização, governança e modelagem MMM para o Uncover Aegis.
//!
//! # NIFs Exportadas
//!
//! | Função                   | MVP | Descrição                                         |
//! |--------------------------|-----|---------------------------------------------------|
//! | `sanitize_and_validate`  |  1  | Remove PII e detecta Prompt Injection             |
//! | `validate_read_only_sql` |  2  | Garante que o SQL da IA seja apenas SELECT        |
//! | `calculate_zscore`       |  3  | Detecta anomalias estatísticas em gastos          |
//! | `calculate_adstock`      |  4  | Adstock + saturação Hill (Marketing Mix Modeling) |

use regex::Regex;
use rustler::{Atom, NifResult};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        threat_detected,
        unsafe_sql,
        insufficient_data,
    }
}

// ===========================================================================
// MVP 1 — Ingestão Segura: Sanitização de PII + Detecção de Prompt Injection
// ===========================================================================

#[rustler::nif(schedule = "DirtyCpu")]
fn sanitize_and_validate(raw_text: String) -> NifResult<(Atom, String)> {
    let cpf_regex = match Regex::new(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b") {
        Ok(re) => re,
        Err(_) => return Ok((atoms::error(), "Falha na compilacao do motor regex de CPF".to_string())),
    };

    let email_regex = match Regex::new(r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}") {
        Ok(re) => re,
        Err(_) => return Ok((atoms::error(), "Falha na compilacao do motor regex de Email".to_string())),
    };

    let after_cpf = cpf_regex.replace_all(&raw_text, "[CPF_REDACTED]").to_string();
    let sanitized = email_regex.replace_all(&after_cpf, "[EMAIL_REDACTED]").to_string();

    let lower = sanitized.to_lowercase();
    let injection_patterns = [
        "ignore todas as instruções",
        "ignore previous instructions",
        "system prompt:",
        "you are now",
        "forget your instructions",
        "act as if",
        "[jailbreak]",
        "dan mode",
    ];

    for pattern in &injection_patterns {
        if lower.contains(pattern) {
            return Ok((
                atoms::threat_detected(),
                format!("Prompt injection bloqueado: padrao '{}' detectado", pattern),
            ));
        }
    }

    Ok((atoms::ok(), sanitized))
}

// ===========================================================================
// MVP 2 — Insights Controlados: SQL Guardrail
// ===========================================================================

#[rustler::nif(schedule = "DirtyCpu")]
fn validate_read_only_sql(query: String) -> NifResult<(Atom, String)> {
    let q_upper = query.trim().to_uppercase();

    if !q_upper.starts_with("SELECT") && !q_upper.starts_with("WITH") {
        return Ok((atoms::unsafe_sql(), "Query deve ser de leitura (iniciar com SELECT ou WITH)".to_string()));
    }

    let forbidden = [
        "INSERT", "UPDATE", "DELETE", "DROP", "ALTER",
        "TRUNCATE", "GRANT", "REVOKE", "CREATE", "REPLACE",
        "EXEC", "EXECUTE", "CALL", "MERGE",
    ];

    for keyword in &forbidden {
        let pattern = format!(r"\b{}\b", keyword);
        match Regex::new(&pattern) {
            Ok(re) if re.is_match(&q_upper) => {
                return Ok((atoms::unsafe_sql(), format!("Keyword de mutacao detectada: {}", keyword)))
            }
            Err(_) => {
                return Ok((atoms::error(), format!("Falha ao compilar regex para keyword: {}", keyword)))
            }
            _ => {}
        }
    }

    Ok((atoms::ok(), query))
}

// ===========================================================================
// MVP 3 — Monitoramento Preditivo: Z-Score para Anomalias de Gasto
// ===========================================================================

#[rustler::nif(schedule = "DirtyCpu")]
fn calculate_zscore(spends: Vec<f64>) -> NifResult<(Atom, f64)> {
    let n = spends.len();
    if n < 2 {
        return Ok((atoms::insufficient_data(), 0.0));
    }

    let n_f = n as f64;
    let mean = spends.iter().sum::<f64>() / n_f;
    let variance = spends.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n_f;
    let std_dev = variance.sqrt();

    if std_dev == 0.0 {
        return Ok((atoms::ok(), 0.0));
    }

    match spends.last() {
        Some(&last_spend) => Ok((atoms::ok(), (last_spend - mean) / std_dev)),
        None => Ok((atoms::error(), 0.0)),
    }
}

// ===========================================================================
// MVP 4 — Marketing Mix Modeling: Adstock com Saturação Hill
// ===========================================================================
//
// O Adstock é o algoritmo central do MMM (Marketing Mix Modeling).
// Modela dois fenômenos reais de mídia:
//
// 1. CARRY-OVER (memória): um anúncio visto hoje ainda influencia compras
//    nos próximos dias/semanas. Controlado por `decay` (0.0–1.0).
//    decay=0.0 → sem memória (efeito apenas no dia)
//    decay=0.7 → 70% do efeito persiste para o próximo período
//
// 2. SATURAÇÃO (lei dos retornos decrescentes): dobrar o investimento não
//    dobra o impacto. Modelado pela curva Hill: f(x) = x^alpha / (x^alpha + K^alpha)
//    alpha > 1 → curva em S (saturação lenta no início, depois rápida)
//    K (half_saturation) → ponto de 50% do impacto máximo
//
// RETORNO:
// - adstock_values: série temporal do impacto acumulado (carry-over aplicado)
// - saturated_values: adstock após curva de saturação Hill (0.0–1.0)
// - contribution_pct: % de contribuição de cada período sobre o total saturado
//
// Exemplo de uso via API:
//   POST /api/v1/mmm/adstock
//   { "spends": [1200,1350,1100,1280], "decay": 0.7, "alpha": 2.0, "half_saturation": 1500.0 }

/// Resultado do cálculo de Adstock retornado ao Elixir.
/// Rustler serializa structs com NifStruct automaticamente como mapas Elixir.
#[derive(rustler::NifStruct)]
#[module = "UncoverAegis.Native.AdstockResult"]
pub struct AdstockResult {
    pub adstock_values: Vec<f64>,
    pub saturated_values: Vec<f64>,
    pub contribution_pct: Vec<f64>,
}

/// Calcula Adstock com carry-over geométrico e saturação Hill.
///
/// # Parâmetros
/// - `spends`: série temporal de gastos (ex: spend diário por campanha)
/// - `decay`: taxa de retenção do efeito entre períodos (0.0 a 1.0)
/// - `alpha`: expoente da curva Hill — controla a forma da saturação
/// - `half_saturation`: valor de gasto onde o impacto é 50% do máximo
///
/// # Retorno
/// - `{:ok, %AdstockResult{}}` — cálculo bem-sucedido
/// - `{:insufficient_data, _}` — lista vazia
/// - `{:error, motivo}` — parâmetros inválidos
#[rustler::nif(schedule = "DirtyCpu")]
fn calculate_adstock(
    spends: Vec<f64>,
    decay: f64,
    alpha: f64,
    half_saturation: f64,
) -> NifResult<(Atom, AdstockResult)> {
    let empty = AdstockResult {
        adstock_values: vec![],
        saturated_values: vec![],
        contribution_pct: vec![],
    };

    if spends.is_empty() {
        return Ok((atoms::insufficient_data(), empty));
    }

    // Validações de parâmetros — Fail-Secure
    if !(0.0..=1.0).contains(&decay) {
        return Ok((atoms::error(), AdstockResult {
            adstock_values: vec![],
            saturated_values: vec![],
            contribution_pct: vec![-1.0], // sentinel: decay fora do intervalo
        }));
    }
    if alpha <= 0.0 || half_saturation <= 0.0 {
        return Ok((atoms::error(), AdstockResult {
            adstock_values: vec![],
            saturated_values: vec![],
            contribution_pct: vec![-2.0], // sentinel: alpha ou K inválidos
        }));
    }

    // Passo 1: Carry-over geométrico (Adstock clássico de Broadbent, 1979)
    // adstock_t = spend_t + decay * adstock_{t-1}
    let mut adstock_values: Vec<f64> = Vec::with_capacity(spends.len());
    let mut prev: f64 = 0.0;
    for &spend in &spends {
        let current = spend + decay * prev;
        adstock_values.push(current);
        prev = current;
    }

    // Passo 2: Saturação Hill — transforma adstock em impacto (0.0 a 1.0)
    // hill(x) = x^alpha / (x^alpha + K^alpha)
    let k_alpha = half_saturation.powf(alpha);
    let saturated_values: Vec<f64> = adstock_values
        .iter()
        .map(|&x| {
            if x <= 0.0 {
                0.0
            } else {
                let x_alpha = x.powf(alpha);
                x_alpha / (x_alpha + k_alpha)
            }
        })
        .collect();

    // Passo 3: Contribuição percentual de cada período sobre o total saturado
    let total_saturated: f64 = saturated_values.iter().sum();
    let contribution_pct: Vec<f64> = if total_saturated > 0.0 {
        saturated_values
            .iter()
            .map(|&s| (s / total_saturated) * 100.0)
            .collect()
    } else {
        vec![0.0; saturated_values.len()]
    };

    Ok((atoms::ok(), AdstockResult {
        adstock_values,
        saturated_values,
        contribution_pct,
    }))
}

// ---------------------------------------------------------------------------
// Registro das NIFs exportadas para o módulo Elixir `UncoverAegis.Native`.
// ---------------------------------------------------------------------------
rustler::init!(
    "Elixir.UncoverAegis.Native",
    [sanitize_and_validate, validate_read_only_sql, calculate_zscore, calculate_adstock]
);
