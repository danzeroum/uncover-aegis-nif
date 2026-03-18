# 📋 Architecture Decision Records (ADRs)

Este diretório documenta as decisões arquiteturais do **Uncover Aegis** que tiveram impacto significativo na estrutura, segurança ou evolubilidade do sistema.

Cada ADR segue o formato: **Contexto → Decisão → Consequências → Trade-offs aceitos → Alternativas rejeitadas.**

> "Protótipos aceitam dívida técnica só na UI. A fundação — concorrência na BEAM, segurança de memória em Rust, contratos de domínio — nasce sólida."

---

## Índice

| ADR | Título | Status | Data |
|-----|--------|--------|------|
| [0001](0001-rust-nif-vs-elixir-puro.md) | Rust NIFs vs Elixir puro para operações CPU-bound | ✅ Aceito | 2026-03-01 |
| [0002](0002-fail-secure-como-padrao.md) | Fail-Secure como padrão universal de tratamento de erros | ✅ Aceito | 2026-03-01 |
| [0003](0003-divida-tecnica-ui-only.md) | Dívida técnica confinada à UI — fundação inegociável | ✅ Aceito | 2026-03-05 |
| [0004](0004-sqlite-vs-postgres.md) | SQLite no PoC com contrato Ecto agnóstico ao banco | ✅ Aceito | 2026-03-05 |
| [0005](0005-adstock-rust-vs-elixir.md) | Adstock MMM em Rust NIF para interatividade em tempo real | ✅ Aceito | 2026-03-15 |

---

## Como ler um ADR

- **Aceito** — decisão em vigor, refletida no código
- **Substituído** — decisão foi revisada; o ADR mais novo referencia este
- **Depreciado** — contexto mudou, decisão não se aplica mais
