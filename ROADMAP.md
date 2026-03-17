# 🗺️ Uncover Aegis — Roadmap

Historico de desenvolvimento do projeto, documentando as decisões arquiteturais
e a evolução progressiva dos três MVPs.

---

## ✅ Fase 1 — Ingestão Segura (MVP 1)

**Objetivo**: Garantir que dados de campanhas sejam sanitizados antes de chegar ao LLM.

- [x] Scaffolding do projeto híbrido Elixir + Rustler
- [x] NIF Rust `sanitize_and_validate` (DirtyCpu)
  - [x] Remoção de CPF brasileiro via Regex DFA O(n)
  - [x] Remoção de e-mail via Regex DFA O(n)
  - [x] Detecção de Prompt Injection (8 padrões PT-BR + EN)
  - [x] Zero `.unwrap()` — padrão Fail-Secure do BuildToValue
- [x] Pipeline Elixir com `Task.async_stream` concorrente
- [x] Testes ExUnit com 6 casos
- [x] README com pitch executivo

---

## ✅ Fase 2 — Insights Controlados (MVP 2)

**Objetivo**: Permitir que o LLM gere SQL sem risco de queries destrutivas.

- [x] NIF Rust `validate_read_only_sql` (DirtyCpu)
  - [x] Allowlist: somente `SELECT` e `WITH` (CTEs)
  - [x] Blocklist com `\b` (word boundary): sem falsos positivos em nomes de colunas
  - [x] 14 keywords de mutação/DDL bloqueadas
- [x] NIF Rust `calculate_zscore` (DirtyCpu)
  - [x] Variância populacional para séries temporais completas
  - [x] Tratamento de desvio padrão zero (sem divisão por zero)
  - [x] Dados insuficientes retornam `:insufficient_data` (não crasham)
- [x] Schema Ecto `CampaignMetric` com validações
- [x] Repositório Ecto (SQLite3) na árvore de supervisão OTP
- [x] Migração `campaign_metrics` com índices
- [x] Módulo `Insights.run_safe_query/1`: SQL guardrail + query Ecto + Z-Score
- [x] 16 testes (NIF unitários + integração com SQLite `:memory:`)
- [x] CI GitHub Actions (matrix Elixir 1.16/1.17, Cargo cache, Clippy)

---

## ✅ Fase 3 — Monitoramento Preditivo (MVP 3)

**Objetivo**: Detectar picos e quedas anômalas nos gastos de campanhas em tempo real.

- [x] `DynamicSupervisor`: gerencia 1 GenServer por campanha, sob demanda
  - [x] `start_campaign/1` idempotente (`already_started` tratado como `:ok`)
  - [x] `stop_campaign/1` gracioso via `:global.whereis_name/1`
  - [x] `restart: :transient` (crashes reiniciados; paradas normais não)
- [x] `CampaignMonitor` (GenServer)
  - [x] Ring buffer `@max_history 50` (previne OOM em processos long-running)
  - [x] Delegação matemática: Z-Score calculado em Rust via NIF
  - [x] Alertas via `Logger.warning` quando |Z| > 3.0
  - [x] `alert_count` e `last_z_score` no estado (audit trail)
  - [x] `:global` registry (prep para cluster Erlang distribuído)
- [x] API pública `Sentinel` com `start_monitoring/1` e `add_spend/2` lazy
- [x] Testes ExUnit: 12 casos cobrindo ciclo de vida, ring buffer, anomalias e isolamento OTP
  - [x] `ExUnit.CaptureLog` para verificar alertas sem inspecionar estado interno
  - [x] IDs únicos por teste (`System.unique_integer`) para isolamento no `:global`
- [x] README atualizado com diagrama completo dos 3 MVPs
- [x] ROADMAP documentando histórico de decisões

---

## 🔮 Fase 4 — Próximos Passos (Futuro)

- [ ] Phoenix LiveView dashboard: visualizar gastos e alertas em tempo real
- [ ] Benchmark `Benchee`: comparar throughput Elixir puro vs NIF Rust
- [ ] Suporte a CNPJ, telefone e outros padrões de PII brasileiros
- [ ] Contagem de tokens para evitar estouro de contexto no LLM
- [ ] Persistir alertas do Sentinel na tabela `campaign_metrics` via Ecto
- [ ] Docker multi-stage: compila Rust + Elixir em imagem única
- [ ] Integração real com OpenAI/Gemini via HTTP (Req/Finch)
- [ ] Cluster Erlang distribuído: Sentinel monitorando campanhas em múltiplos nós
