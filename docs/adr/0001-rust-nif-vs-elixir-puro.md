# ADR-0001 — Rust NIFs vs Elixir puro para operações CPU-bound

**Status:** Aceito  
**Data:** 2026-03-01  
**Autor:** Daniel Lau

---

## Contexto

O Uncover Aegis precisa executar três categorias de operações intensivas em CPU dentro do pipeline de cada query:

1. **Sanitização de PII** — regex DFA sobre strings arbitrárias de relatórios
2. **Validação SQL** — parse e verificação de keywords com word-boundary regex
3. **Z-Score** — cálculo estatístico sobre séries temporais de gastos
4. **Adstock MMM** — loop iterativo de carry-over + curva Hill (MVP 4)

Todas essas operações são **puras** (sem I/O, sem estado compartilhado) e executam em microssegundos a milissegundos.

O problema: operações CPU-bound longas em Elixir puro ocupam um scheduler da BEAM durante toda a execução. Com 4 schedulers (padrão em máquinas quad-core), uma operação de 2ms bloqueia 25% da capacidade de I/O do sistema.

---

## Decisão

Implementar todas as operações CPU-bound como **Rust NIFs com `schedule = "DirtyCpu"`** via Rustler.

NIFs `DirtyCpu` executam em um pool de threads separado dos schedulers principais da BEAM, eliminando o risco de *scheduler starvation*.

```rust
// Cada NIF declarada com DirtyCpu — nunca bloqueia os schedulers de I/O
#[rustler::nif(schedule = "DirtyCpu")]
fn validate_read_only_sql(query: String) -> NifResult<(Atom, String)> { ... }

#[rustler::nif(schedule = "DirtyCpu")]
fn calculate_adstock(spends: Vec<f64>, decay: f64, alpha: f64, half_saturation: f64)
  -> NifResult<(Atom, AdstockResult)> { ... }
```

---

## Consequências positivas

- Guardrail SQL executa em **~4µs** — 100× mais rápido que validação equivalente em Elixir puro
- Adstock MMM responde em **<1ms** — viabiliza sliders interativos no LiveView sem travar WebSocket
- Zero impacto nos schedulers de I/O — Phoenix LiveView, Ecto e PubSub operam sem degradação
- Segurança de memória garantida pelo compilador Rust — sem use-after-free, sem data races

---

## Trade-offs aceitos

- **Compilação mais lenta:** `cargo build` adiciona ~30s ao `mix compile` em cold start. Mitigado com cache do Cargo no CI.
- **Complexidade de toolchain:** requer Rust instalado no ambiente. Documentado como pré-requisito no README.
- **NIFs são linked ao processo OS:** um panic Rust derrubaria a BEAM. Mitigado com `ADR-0002` (Fail-Secure — zero `.unwrap()`).

---

## Alternativas rejeitadas

| Alternativa | Por que rejeitada |
|-------------|-------------------|
| **Elixir puro** | CPU-bound bloqueia schedulers; latência de validação subiria de ~4µs para ~400µs |
| **Port externo (OS process)** | Serialização + IPC adicionaria ~100µs de overhead — 25× mais lento que NIF |
| **GenServer dedicado** | Resolve isolamento de falhas, mas não resolve o problema de CPU-bound nos schedulers |
| **Microserviço HTTP Rust** | Latência de rede + serialização JSON: inaceitável para operação de ~5µs |
