# ADR-0004 — SQLite no PoC com contrato Ecto agnóstico ao banco

**Status:** Aceito  
**Data:** 2026-03-05  
**Autor:** Daniel Lau

---

## Contexto

O Uncover Aegis precisa de um banco de dados relacional para armazenar `campaign_metrics` e executar queries analíticas geradas pelo LLM (GROUP BY, SUM, filtros por plataforma e período).

O projeto é um PoC local focado em validar o pipeline de segurança (Guardrail Rust + Z-Score). A infraestrutura de banco não é o diferencial — o contrato da camada de domínio é.

---

## Decisão

Usar **SQLite via `ecto_sqlite3`** no PoC, mantendo o contrato do `Repo` e das queries Ecto **completamente agnóstico ao banco**.

Nenhuma query usa SQL raw específico de SQLite. Todas usam a DSL Ecto:

```elixir
# ✅ Ecto DSL — funciona em SQLite, PostgreSQL e MySQL sem alteração
from(m in "campaign_metrics",
  group_by: [m.campaign_id, m.platform],
  order_by: [desc: sum(m.spend)],
  select: %{campaign_id: m.campaign_id, spend: sum(m.spend)}
)
```

A migração para PostgreSQL em produção exige apenas:
1. Trocar `ecto_sqlite3` por `postgrex` no `mix.exs`
2. Atualizar a string de conexão em `config/prod.exs`
3. Zero alterações em `insights.ex`, `metrics_controller.ex` ou qualquer módulo de domínio

---

## Consequências positivas

- **Zero dependências externas** para rodar o PoC — `mix ecto.create` funciona sem Docker
- **CI mais rápido** — banco em memória (`:memory:`) nos testes, sem setup de container
- **Contrato preservado** — a promessa de migração futura é verificável: nenhuma query usa features SQLite-específicas

---

## Trade-offs aceitos

- **Sem transações distribuídas:** SQLite não suporta múltiplas conexões de escrita concorrentes. Aceitável para PoC de leitura analítica.
- **Sem `EXPLAIN ANALYZE`:** diagnóstico de performance de queries é limitado no SQLite. Em produção com PostgreSQL, isso seria essencial.
- **Seeds estáticos:** 24 registros fixos em `priv/repo/seeds.exs`. Volume insuficiente para testes de performance reais.

---

## Alternativas rejeitadas

| Alternativa | Por que rejeitada |
|-------------|-------------------|
| **PostgreSQL desde o início** | Adicionaria Docker como dependência obrigatória para rodar o PoC localmente |
| **Banco em memória ETS** | Sem suporte a SQL — inviabilizaria o pipeline NL→SQL que é o core do MVP 2 |
| **SQL raw** | Acoplaria o código ao dialeto SQLite, tornando a migração para PostgreSQL manual e arriscada |
