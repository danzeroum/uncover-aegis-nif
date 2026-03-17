//! aegis_core — Núcleo de sanitização de dados CPU-bound para o Uncover Aegis.
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

use regex::Regex;
use rustler::{Atom, NifResult};

// Atoms Elixir retornados como primeiro elemento da tupla de resultado.
// Equivalentes a :ok, :error, :threat_detected no Elixir.
mod atoms {
    rustler::atoms! {
        ok,
        error,
        threat_detected,
    }
}

/// Sanitiza um texto de campanha de marketing:
/// 1. Remove PII (CPF no formato bràsileiro) substituindo por `[REDACTED]`.
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
    // Passo 1: Compilar regex de CPF com tratamento de erro explícito.
    // A crate `regex` usa DFA, garantindo O(n) sem backtracking catastrófico.
    // Formato: 000.000.000-00
    let cpf_regex = match Regex::new(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b") {
        Ok(re) => re,
        Err(_) => {
            return Ok((
                atoms::error(),
                "Falha na compilacao do motor regex de CPF".to_string(),
            ))
        }
    };

    // Passo 2: Regex de e-mail (segundo vetor de PII mais comum em relatorios)
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
    // replace_all retorna Cow<str>, .to_string() materializa sem alocações extras.
    let after_cpf = cpf_regex
        .replace_all(&raw_text, "[CPF_REDACTED]")
        .to_string();

    let sanitized = email_regex
        .replace_all(&after_cpf, "[EMAIL_REDACTED]")
        .to_string();

    // Passo 4: Detecção de Prompt Injection por heurística.
    // Conversão para lowercase evita bypass por capitalização ("IGNORE", "Ignore", etc.)
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

    // Passo 5: Retorno seguro — dados limpos de volta para a BEAM.
    Ok((atoms::ok(), sanitized))
}

// Registra as funções NIF exportadas para o Elixir.
// O atom Elixir.UncoverAegis.Native deve corresponder exatamente
// ao nome do módulo Elixir que declara `use Rustler`.
rustler::init!("Elixir.UncoverAegis.Native", [sanitize_and_validate]);
