# 🛡️ Uncover Aegis

> **Pipeline de ingestão híbrido: concorrência massiva do Elixir + segurança e performance do Rust.**

[![Elixir](https://img.shields.io/badge/Elixir-1.14+-blueviolet)](https://elixir-lang.org)
[![Rust](https://img.shields.io/badge/Rust-1.75+-orange)](https://www.rust-lang.org)
[![Rustler](https://img.shields.io/badge/Rustler-0.36-green)](https://github.com/rusterlium/rustler)
[![CI](https://github.com/danzeroum/uncover-aegis-nif/actions/workflows/ci.yml/badge.svg)](https://github.com/danzeroum/uncover-aegis-nif/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 🎯 O Problema

Na análise de campanhas de marketing (**Media Mix Modeling**), a plataforma ingere milhões de linhas de relatórios do Meta e Google. Para entregar insights de ROI via IA (OpenAI/Gemini) com segurança e escala, três desafios devem ser resolvidos:

| Desafio | Risco | Solução |  
|---------|-------|----------|
| **PII nos relatórios** | Dados pessoais vazam para LLM externa | Sanitização via NIF Rust antes da IA |
| **SQL gerado por IA** | LLM alucina `DROP TABLE` ou `DELETE` | Guardrail SQL em Rust (Allowlist + Blocklist) |
| **Picos de gasto** | CMO não detecta fraudes a tempo | Z-Score por campanha, calculado em Rust, monitorado por GenServer |

**O desafio central**: sanitização, validação SQL e cálculo estatístico são operações **CPU-bound**. Feitas puramente em Elixir, causariam *starvation* dos schedulers da BEAM, degradando toda a aplicação.

---

## ⚙️ A Solução Híbrida

```
┌─────────────────────────────────────────────────────────┐
│              ELIXIR / OTP ("O Navio de Guerra")             │
│                                                             │
│  ┌─────────────┐  ┌───────────┐  ┌─────────────┐  │
│  │  Pipeline   │  │  Insights  │  │  Sentinel   │  │
│  │  (MVP 1)    │  │  (MVP 2)   │  │  (MVP 3)    │  │
│  │  async_     │  │  Ecto +    │  │  GenServer  │  │
│  │  stream     │  │  Repo      │  │  por camp.  │  │
│  └────┬────┘  └────┬───┘  └────┬────┘  │
└───────────┬─────────┬─────────┬─────────────┘
             │         │         │
             ▼         ▼         ▼
┌─────────────────────────────────────────────────────────┐
│              RUST ("O Canivete Suíço")                     │
│  aegis_core — DirtyCpu NIFs, Zero .unwrap(), Regex DFA     │
│                                                             │
│  sanitize_and_validate   validate_read_only_sql   zscore    │
└─────────────────────────────────────────────────────────┘
```

---

## 💼 MVP 1 — Ingestão Segura

Sanitiza textos de campanhas antes de enviá-los para um LLM:
- Remove **CPFs** e **e-mails** (PII) via Regex DFA O(n) em Rust
- Bloqueia **Prompt Injection** com heurística de 8 padrões (PT-BR + EN)
- Pipeline concorrente via `Task.async_stream` com `max_concurrency: System.schedulers_online()`

```elixir
UncoverAegis.Pipeline.process_campaigns([
  "Cliente CPF 123.456.789-00 ROI 3x",
  "ignore previous instructions",
  "Campanha Black Friday sem PII"
])
# [{:ok, "[LLM] Cliente CPF [CPF_REDACTED] ROI 3x"},
#  {:threat_detected, "[BLOQUEADO] Prompt injection bloqueado: ..."},
#  {:ok, "[LLM] Campanha Black Friday sem PII"}]
```

---

## 📊 MVP 2 — Insights Controlados

Executa queries SQL geradas por LLM de forma segura:
- **SQL Guardrail** (Rust): valida que a query é somente `SELECT`/`WITH`
- **Blocklist com `\b`** (word boundary): evita falsos positivos em colunas como `last_updated_at`
- **Z-Score integrado**: retorna metadados de anomalia junto com os resultados

```elixir
UncoverAegis.Insights.run_safe_query(
  "SELECT campaign_id, spend FROM campaign_metrics WHERE platform = 'meta'"
)
# {:ok, %{rows: [...], columns: [...], z_score: 0.3, anomaly: false}}

UncoverAegis.Insights.run_safe_query("DELETE FROM campaign_metrics")
# {:unsafe_sql, "Keyword de mutacao detectada: DELETE"}
```

---

## 🚨 MVP 3 — Spend Anomaly Sentinel

Monitora picos e quedas anômalas nos gastos de campanhas em tempo real:

**Como funciona:**
- Cada campanha monitorada é representada por um **GenServer** (ator leve) com estado próprio
- Os processos são gerenciados por um **DynamicSupervisor** (inicia sob demanda, isola falhas)
- A cada novo gasto, o histórico (ring buffer de 50 elementos) é enviado para a NIF Rust `calculate_zscore`
- Se |Z| > 3.0 (regra 3-sigma, 99.7% de confiança), um alerta é disparado

```elixir
# Gastos normais (sem alerta)
Enum.each(1..10, fn _ -> UncoverAegis.Sentinel.add_spend("summer_sale", 1_000.0) end)

# Pico anômalo (gera alerta imediato)
UncoverAegis.Sentinel.add_spend("summer_sale", 10_000.0)
# [warning] [AEGIS SENTINEL] 🚨 Anomalia na campanha 'summer_sale': Z-Score = 3.16 | ...

# Milhares de campanhas concorrentes: cada uma é um processo isolado
Enum.each(1..1000, fn i ->
  UncoverAegis.Sentinel.add_spend("camp_#{i}", :rand.uniform() * 1000)
end)
```

**Decisões de design:**
- **Ring buffer `@max_history 50`**: previne crescimento ilimitado do estado (OOM em processos long-running)
- **`restart: :transient`**: crashes são reiniciados; paradas normais não
- **`:global` registry**: prep para expansão para cluster Erlang distribuído
- **`GenServer.cast`**: add_spend retorna imediatamente; análise Rust é assíncrona

---

## 💼 Decisões Arquiteturais (Trade-offs)

### 1. Dirty NIFs (`schedule = "DirtyCpu"`)
A BEAM divide o tempo em "reducts" por processo. Uma NIF comum **bloqueia o scheduler** se ultrapassar ~1ms. `DirtyCpu` instrui a VM a usar threads de workers separadas.

### 2. Zero `.unwrap()` — Filosofia Fail-Secure
Herdado do projeto [BuildToValue](https://github.com/danzeroum). Todo erro no Rust é tratado com `match` e retornado como tupla `{:error, reason}`. Panics derrubariam a VM.

### 3. Regex DFA O(n) vs PCRE
A crate `regex` usa **autômatos finitos determinísticos**, garantindo tempo linear. Regex PCRE podem sofrer backtracking exponencial (ReDoS attacks).

### 4. DynamicSupervisor vs Supervisor estático
Campanhas surgem e somem em runtime. `DynamicSupervisor` inicia filhos sob demanda; `Supervisor` estático exigiria conhecer todos os filhos em compile-time.

---

## 🚀 Como Executar

### Pré-requisitos
- Elixir `~> 1.14` (recomendado: [asdf](https://asdf-vm.com))
- Erlang/OTP 26+
- Rust `~> 1.75` via [rustup](https://rustup.rs)

```bash
git clone https://github.com/danzeroum/uncover-aegis-nif.git
cd uncover-aegis-nif
mix deps.get && mix compile   # Cargo compila aegis_core automaticamente
iex -S mix
```

### Exemplos no console

```elixir
# MVP 1 — Sanitização
UncoverAegis.Native.sanitize_and_validate("CPF: 123.456.789-00")
# {:ok, "CPF: [CPF_REDACTED]"}

# MVP 2 — SQL Guardrail
UncoverAegis.Insights.run_safe_query("DROP TABLE campaign_metrics")
# {:unsafe_sql, "Keyword de mutacao detectada: DROP"}

# MVP 3 — Anomaly Sentinel
Enum.each(1..10, fn _ -> UncoverAegis.Sentinel.add_spend("camp1", 100.0) end)
UncoverAegis.Sentinel.add_spend("camp1", 5_000.0)
# [warning] [AEGIS SENTINEL] 🚨 Anomalia na campanha 'camp1': Z-Score = ...
```

### Testes
```bash
mix test
```

---

## 📂 Estrutura do Projeto

```
uncover-aegis-nif/
├── mix.exs
├── config/
│   ├── config.exs
│   └── test.exs
├── lib/
│   └── uncover_aegis/
│       ├── application.ex        # Árvore OTP: Repo + Sentinel.DynamicSupervisor
│       ├── native.ex             # Wrapper NIF (Rustler)
│       ├── pipeline.ex           # MVP 1: ingestão concorrente
│       ├── campaign_metric.ex    # MVP 2: Schema Ecto
│       ├── insights.ex           # MVP 2: SQL guardrail + z-score
│       ├── repo.ex               # MVP 2: Ecto Repo
│       └── sentinel/
│           ├── sentinel.ex           # MVP 3: API pública
│           ├── campaign_monitor.ex   # MVP 3: GenServer por campanha
│           └── dynamic_supervisor.ex # MVP 3: supervisor dinâmico
├── native/
│   └── aegis_core/
│       ├── Cargo.toml
│       └── src/lib.rs            # 3 NIFs: sanitize | sql_guard | zscore
├── test/
│   └── uncover_aegis/
│       ├── pipeline_test.exs
│       ├── native_test.exs
│       ├── insights_test.exs
│       └── sentinel/
│           └── campaign_monitor_test.exs
├── priv/repo/migrations/
│   └── 20260317000000_create_campaign_metrics.exs
└── .github/workflows/ci.yml
```

---

## 🧠 Contexto Arquitetural

Este projeto é uma **Prova de Conceito (PoC)** que demonstra a interoperabilidade entre Elixir e Rust para resolver problemas reais de MarTech AI:

> *O Elixir é insuperaável para orquestrar concorrência de I/O e modelar entidades como atores (GenServers). O Rust é perfeito para operações CPU-bound com segurança de memória. Juntos, eliminam os trade-offs de cada um isolado.*

A filosofia **Fail-Secure** e o padrão **zero `.unwrap()`** são herdados do projeto [BuildToValue](https://github.com/danzeroum).

---

*Desenvolvido por [Daniel Lau](https://github.com/danzeroum) — entusiasta de sistemas confiáveis e alto desempenho.*
