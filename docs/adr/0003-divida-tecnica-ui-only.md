# ADR-0003 — Dívida técnica confinada à UI — fundação inegociável

**Status:** Aceito  
**Data:** 2026-03-05  
**Autor:** Daniel Lau

---

## Contexto

Em projetos de prototipação rápida, há pressão constante para fazer atalhos em qualquer camada para acelerar a entrega. A questão é: **onde os atalhos são aceitáveis e onde são proibidos?**

O Uncover Aegis foi desenvolvido iterativamente em 4 MVPs. Em cada fase, decisões explícitas foram tomadas sobre onde aceitar dívida técnica e onde não aceitar.

---

## Decisão

Adotar uma política explícita de **confinamento de dívida técnica à camada de UI/apresentação**. A fundação — contratos de domínio, concorrência na BEAM, segurança de memória em Rust — é tratada como inegociável desde o MVP 1.

### O que é fundação (sem atalhos)

| Camada | Decisão sem atalho | Evidência no código |
|--------|--------------------|---------------------|
| **Contratos de domínio** | `Insights.run_safe_query/1` tem assinatura estável desde MVP 2 | `insights.ex` |
| **Concorrência BEAM** | `DynamicSupervisor` + `GenServer` por campanha desde MVP 3 | `sentinel/dynamic_supervisor.ex` |
| **Segurança de memória Rust** | Zero `.unwrap()` desde MVP 1 | `native/aegis_core/src/lib.rs` |
| **Isolamento de falhas** | `:restart: :transient` no Sentinel | `campaign_monitor.ex` |
| **Observabilidade** | `TelemetryStore` com ETS desde o MVP 4 | `telemetry_store.ex` |

### O que é UI (atalhos aceitos explicitamente)

| Atalho aceito | Justificativa | Débito técnico registrado |
|---------------|---------------|---------------------------|
| **LlmMock** em vez de Ollama real | Validar pipeline sem dependência externa | `ROADMAP.md` Fase 4 |
| **SQLite** em vez de PostgreSQL | PoC local — contrato Ecto preserva migração futura | `ADR-0004` |
| **Chart.js via CDN** | Gráficos funcionais sem build pipeline JS | Roadmap: substituir por LiveSvelte |
| **Sem autenticação** | Fora do escopo do PoC de segurança de dados | `ROADMAP.md` MVP 6 (multi-tenant) |
| **Seeds estáticos** | 24 registros fixos em vez de gerador dinâmico | `priv/repo/seeds.exs` |

---

## Consequências positivas

- A evolução para produção **não exige reescritas** na camada de domínio
- Novos MVPs adicionam funcionalidades sem quebrar contratos existentes
- A dívida técnica é **visível e rastreável** — nenhum atalho foi feito às cegas

---

## Trade-offs aceitos

- **UI menos polida:** gráficos via CDN em vez de pipeline otimizado
- **Sem autenticação no PoC:** risco mitigado pelo fato de ser ambiente local
- **LlmMock limita demos:** apenas 6 perguntas fixas funcionam sem Ollama rodando

---

## Alternativas rejeitadas

| Alternativa | Por que rejeitada |
|-------------|-------------------|
| **Atalhos na concorrência** (ex: Task.async sem supervisão) | Falhas silenciosas em produção; impossível de debugar |
| **Atalhos no guardrail** (ex: validar SQL em Elixir puro) | Scheduler starvation + sem garantias de segurança de memória |
| **Contratos de domínio instáveis** (ex: mudar assinatura a cada MVP) | Quebraria todos os testes de integração e a API REST |
