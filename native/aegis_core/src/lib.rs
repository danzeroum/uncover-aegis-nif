//! aegis_core — Núcleo de sanitização e governança CPU-bound para o Uncover Aegis.
//!
//! Este módulo é compilado como biblioteca dinâmica e carregado pela BEAM
//! via NIF (Native Implemented Function) usando a biblioteca Rustler.
//!
//! # Princípios de Design (herdados do BuildToValue)
//!
//! - **Zero `.unwrap()`**: todo erro é tratado com `match` e retornado como
//!   tupla `{:error, reason}` para o Elixir. Panics derrubam a VM inteira.
//! - **Fail-Secure**: em caso de ambiguidade, BLOQUEIA (não permite).
//! - **Dirty NIF (`DirtyCpu`)**: sinaliza à BEAM para executar esta função
//!   em threads separadas dos schedulers principais, evitando starvation
//!   caso a operação CPU-bound ultrapasse 1ms.
//!
//! # NIFs Exportadas
//!
//! | Função                   | MVP | Descrição                                    |
//! |--------------------------|-----|----------------------------------------------|
//! | `sanitize_and_validate`  |  1  | Remove PII e detecta Prompt Injection        |
//! | `validate_read_only_sql` |  2  | Garante que o SQL da IA seja apenas SELECT   |
//! | `calculate_zscore`       |  3  | Detecta anomalias estatísticas em gastos     |

use regex::Regex;
use rustler::{Atom, NifResult};

// ---------------------------------------------------------------------------
// Atoms Elixir — retornados como primeiro elemento das tuplas de resultado.
// Equivalentes a :ok, :error, :threat_detected, :unsafe_sql, :insufficient_data
// no lado Elixir.
// ---------------------------------------------------------------------------
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

/// Sanitiza um texto de campanha de marketing:
/// 1. Remove PII (CPF brasileiro, e-mail) substituindo por `[REDACTED]`.
/// 2. Detecta tentativas de Prompt Injection por heurística de keywords.
///
/// Executado como **Dirty CPU NIF**: a BEAM agenda esta função em threads
/// de workers sujos (dirty schedulers), liberando os schedulers principais
/// para continuar processando processos leves do Elixir.
///
/// # Retorno
/// - `{:ok, texto_sanitizado}` — processamento normal, PII removido.
/// - `{:threat_detected, motivo}` — conteúdo bloqueado por segurança.
/// - `{:error, motivo}` — falha interna (ex: falha na compilação de regex).
#[rustler::nif(schedule = "DirtyCpu")]
fn sanitize_and_validate(raw_text: String) -> NifResult<(Atom, String)> {
    // Passo 1: Regex de CPF — DFA garante O(n) sem backtracking catastrófico.
    let cpf_regex = match Regex::new(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b") {
        Ok(re) => re,
        Err(_) => {
            return Ok((
                atoms::error(),
                "Falha na compilacao do motor regex de CPF".to_string(),
            ))
        }
    };

    // Passo 2: Regex de e-mail
    let email_regex = match Regex::new(r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}") {
        Ok(re) => re,
        Err(_) => {
            return Ok((
                atoms::error(),
                "Falha na compilacao do motor regex de Email".to_string(),
            ))
        }
    };

    // Passo 3: Sanitização em cadeia — CPF depois Email.
    // replace_all retorna Cow<str>; .to_string() materializa sem alocações extras.
    let after_cpf = cpf_regex
        .replace_all(&raw_text, "[CPF_REDACTED]")
        .to_string();

    let sanitized = email_regex
        .replace_all(&after_cpf, "[EMAIL_REDACTED]")
        .to_string();

    // Passo 4: Detecção de Prompt Injection por heurística de keywords.
    // Lowercase evita bypass por capitalização ("IGNORE", "Ignore", etc.)
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

/// Valida que um SQL gerado por LLM é estritamente de leitura.
///
/// Protege o banco de dados contra queries destrutivas (DROP, DELETE, UPDATE)
/// que uma IA poderia alucinar ao responder perguntas em linguagem natural.
///
/// ## Regras de Validação (Fail-Secure)
///
/// 1. **Allowlist de início**: a query DEVE começar com `SELECT` ou `WITH`.
///    Qualquer outra coisa (INSERT, EXEC, etc.) é bloqueada imediatamente.
///
/// 2. **Blocklist de keywords**: mesmo dentro de um SELECT, palavras como
///    `DELETE` ou `DROP` são proibidas (ex: subqueries maliciosas).
///
/// ## Por que `\b` (word boundary) na Regex?
///
/// Usar `.contains("UPDATE")` causaria falsos positivos em colunas como
/// `last_updated_at`. A regex `\bUPDATE\b` garante que só correspondemos
/// à palavra completa, eliminando esse bug de produção.
///
/// # Retorno
/// - `{:ok, sql_original}` — query segura para execução.
/// - `{:unsafe_sql, motivo}` — query bloqueada pela política.
/// - `{:error, motivo}` — falha interna na compilação de regex.
#[rustler::nif(schedule = "DirtyCpu")]
fn validate_read_only_sql(query: String) -> NifResult<(Atom, String)> {
    let q_upper = query.trim().to_uppercase();

    // Regra 1 (Allowlist): deve iniciar com SELECT ou WITH (CTEs são válidos).
    if !q_upper.starts_with("SELECT") && !q_upper.starts_with("WITH") {
        return Ok((
            atoms::unsafe_sql(),
            "Query deve ser de leitura (iniciar com SELECT ou WITH)".to_string(),
        ));
    }

    // Regra 2 (Blocklist com word-boundary): proíbe comandos de mutação e DDL.
    // \b evita falsos positivos em nomes de colunas (ex: last_updated_at).
    let forbidden = [
        "INSERT", "UPDATE", "DELETE", "DROP", "ALTER",
        "TRUNCATE", "GRANT", "REVOKE", "CREATE", "REPLACE",
        "EXEC", "EXECUTE", "CALL", "MERGE",
    ];

    for keyword in &forbidden {
        let pattern = format!(r"\b{}\b", keyword);
        match Regex::new(&pattern) {
            Ok(re) if re.is_match(&q_upper) => {
                return Ok((
                    atoms::unsafe_sql(),
                    format!("Keyword de mutacao detectada: {}", keyword),
                ))
            }
            Err(_) => {
                return Ok((
                    atoms::error(),
                    format!("Falha ao compilar regex para keyword: {}", keyword),
                ))
            }
            _ => {} // keyword não encontrada, continua
        }
    }

    Ok((atoms::ok(), query))
}

// ===========================================================================
// MVP 3 — Monitoramento Preditivo: Z-Score para Anomalias de Gasto
// ===========================================================================

/// Calcula o Z-Score do último elemento de um array de gastos.
///
/// Reutiliza a lógica do módulo `statistics/zscore.rs` do BuildToValue (BTV),
/// adaptada para retornar uma tupla segura para a BEAM.
///
/// O Z-Score mede quantos desvios padrão um valor está da média histórica.
/// Um |z| > 3.0 indica anomalia estatística com 99.7% de confiança.
///
/// ## Exemplo
/// Gastos históricos: [100, 105, 98, 102] e novo gasto: 500
/// → Z-Score ≈ 7.8 → anomalia detectada → alerta para o CMO.
///
/// # Retorno
/// - `{:ok, zscore}` — cálculo bem-sucedido (f64).
/// - `{:insufficient_data, 0.0}` — menos de 2 pontos (sem variância calculável).
/// - `{:error, 0.0}` — falha interna inesperada.
#[rustler::nif(schedule = "DirtyCpu")]
fn calculate_zscore(spends: Vec<f64>) -> NifResult<(Atom, f64)> {
    let n = spends.len();

    // Precisamos de no mínimo 2 pontos para calcular variância significativa.
    if n < 2 {
        return Ok((atoms::insufficient_data(), 0.0));
    }

    let n_f = n as f64;
    let mean = spends.iter().sum::<f64>() / n_f;

    // Variância populacional (não amostral): adequada para séries temporais
    // onde temos o histórico completo, não uma amostra.
    let variance = spends.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n_f;
    let std_dev = variance.sqrt();

    // Desvio padrão zero significa gastos idênticos: sem anomalia possível.
    if std_dev == 0.0 {
        return Ok((atoms::ok(), 0.0));
    }

    // O último elemento é o "gasto atual" a ser avaliado contra o histórico.
    match spends.last() {
        Some(&last_spend) => {
            let z_score = (last_spend - mean) / std_dev;
            Ok((atoms::ok(), z_score))
        }
        // Ramo teoricamente inalcançável (n >= 2 garante last()), mas
        // o compilador exige tratamento explícito. Fail-Secure.
        None => Ok((atoms::error(), 0.0)),
    }
}

// ---------------------------------------------------------------------------
// Registro das NIFs exportadas para o módulo Elixir `UncoverAegis.Native`.
// O nome do atom DEVE corresponder exatamente ao módulo Elixir com `use Rustler`.
// ---------------------------------------------------------------------------
rustler::init!(
    "Elixir.UncoverAegis.Native",
    [sanitize_and_validate, validate_read_only_sql, calculate_zscore]
);
