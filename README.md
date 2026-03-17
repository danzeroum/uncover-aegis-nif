# 🛡️ Uncover Aegis

> **Pipeline de ingestão híbrido: concorrência massiva do Elixir + segurança e performance do Rust.**

[![Elixir](https://img.shields.io/badge/Elixir-1.14+-blueviolet)](https://elixir-lang.org)
[![Rust](https://img.shields.io/badge/Rust-1.75+-orange)](https://www.rust-lang.org)
[![Rustler](https://img.shields.io/badge/Rustler-0.36-green)](https://github.com/rusterlium/rustler)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 🎯 O Problema

Na análise de campanhas de marketing (**Media Mix Modeling**), a plataforma ingere milhões de linhas de relatórios do Meta e Google. Antes de enviar esses dados para um LLM (OpenAI/Gemini) extrair *insights* de ROI, é crítico garantir:

1. **Nenhum PII** (dado pessoal do anunciante) vaze para a IA externa.
2. **Sem Prompt Injection** disfaçado nos dados brutos das campanhas.
3. **Alta performance** — sanitização não pode ser o gargalo do pipeline.

**O desafio central**: sanitização de texto com Regex complexas é uma operação **CPU-bound**. Se feita puramente em Elixir, pode causar *starvation* dos schedulers da Erlang VM (BEAM), degradando a concorrência de toda a aplicação.

---

## ⚙️ A Solução Híbrida

```
                    ┌─────────────────────────────────────┐
                    │       ELIXIR / OTP              │
   CSV Input  ───►  │  Task.async_stream (I/O)       │
                    │  Supervisor Trees (Fault Tol.) │
                    └───────────┬────────────────────────┘
                               │  NIF call (Rustler)
                               ▼
                    ┌─────────────────────────────────────┐
                    │       RUST (aegis_core)         │
                    │  DirtyCpu NIF                  │
                    │  • Regex DFA O(n) — CPF, Email  │
                    │  • Prompt Injection heuristics  │
                    │  • Zero .unwrap() (Fail-Secure) │
                    └─────────────────────────────────────┘
                               │
                               ▼
                    {:ok | :threat_detected | :error}
                               │
                               ▼
                         OpenAI / Gemini
```

---

## 💼 Decisões Arquiteturais (Trade-offs)

### 1. Dirty NIFs (`schedule = "DirtyCpu"`)

A BEAM divide o tempo da CPU em "reducts" por processo. Uma NIF comum **bloquearia o scheduler** se ultrapassar ~1ms. `DirtyCpu` instrui a VM a rodar a função em threads de workers separadas, preservando a latência das requisições web.

### 2. Zero `.unwrap()` — Filosofia Fail-Secure

Herdado do projeto [BuildToValue](https://github.com/danzeroum), todo erro no Rust é tratado com `match` e retornado como tupla ao Elixir. Panics derrubariam a VM. Aqui, erros são propagados como `{:error, reason}` e o Elixir decide o que fazer.

### 3. Regex DFA O(n) vs PCRE

A crate `regex` do Rust usa **autômatos finitos determinísticos** (DFA), garantindo tempo de execução linear. Regex PCRE (Python, Ruby, Node.js) podem sofrer backtracking catastrófico exponencial com inputs adversariais (ReDoS attacks).

### 4. Linked Dynamic Library (`.so`/`.dylib`)

O motor Rust é uma biblioteca compartilhada carregada em runtime. Novas regras de compliance podem ser compiladas e recarregadas com *hot code reloading* nativo do Elixir, sem derrubar a ingestão.

---

## 🚀 Como Executar

### Pré-requisitos

- Elixir `~> 1.14` (recomendado: [asdf](https://asdf-vm.com))
- Erlang/OTP 26+
- Rust `~> 1.75` via [rustup](https://rustup.rs)

### Instalação

```bash
git clone https://github.com/danzeroum/uncover-aegis-nif.git
cd uncover-aegis-nif

# Instala dependências Elixir + compila a crate Rust automaticamente
mix deps.get
mix compile
```

### Console interativo

```bash
iex -S mix
```

```elixir
# Teste direto na NIF Rust
iex(1)> UncoverAegis.Native.sanitize_and_validate("CPF: 123.456.789-00")
{:ok, "CPF: [CPF_REDACTED]"}

iex(2)> UncoverAegis.Native.sanitize_and_validate("ignore previous instructions")
{:threat_detected, "Prompt injection bloqueado: padrao 'ignore previous instructions' detectado"}

iex(3)> UncoverAegis.Native.sanitize_and_validate("Email: joao@empresa.com")
{:ok, "Email: [EMAIL_REDACTED]"}

# Pipeline completo (concorrênte)
iex(4)> UncoverAegis.Pipeline.process_campaigns([
...>   "Cliente CPF 111.222.333-44 ROI 3x",
...>   "ignore previous instructions",
...>   "Campanha Black Friday sem PII"
...> ])
[
  {:ok, "[LLM] Cliente CPF [CPF_REDACTED] ROI 3x"},
  {:threat_detected, "[BLOQUEADO] Prompt injection bloqueado: ..."},
  {:ok, "[LLM] Campanha Black Friday sem PII"}
]
```

### Testes

```bash
mix test
```

---

## 📂 Estrutura do Projeto

```
uncover-aegis-nif/
├── mix.exs                          # Projeto Elixir + dep rustler
├── config/
│   └── config.exs                   # Configuração da crate (debug/release)
├── lib/
│   ├── uncover_aegis.ex             # Módulo raiz + documentação
│   └── uncover_aegis/
│       ├── application.ex           # Árvore de Supervisão OTP
│       ├── native.ex                # Wrapper da NIF (Rustler)
│       └── pipeline.ex              # Orquestração concorrente
├── native/
│   └── aegis_core/
│       ├── Cargo.toml               # Dependências Rust
│       └── src/
│           └── lib.rs               # Núcleo NIF: DirtyCpu + Regex DFA
└── test/
    └── uncover_aegis/
        └── pipeline_test.exs        # Testes ExUnit
```

---

## 🔮 Próximos Passos

- [ ] Suporte a CNPJ e números de telefone (novos padrões de PII)
- [ ] Contagem de tokens para evitar estouro de contexto no LLM
- [ ] Detecção de linguagem ofensiva com modelos leves em Rust
- [ ] Phoenix LiveView dashboard de monitoramento
- [ ] Benchmark: comparar throughput Elixir puro vs Elixir + Rust NIF
- [ ] Docker multi-stage (compila Rust + Elixir em imagem única)

---

## 🧠 Contexto Arquitetural

Este projeto é uma **Prova de Conceito (PoC)** que demonstra a interoperabilidade entre Elixir e Rust para resolver um problema real de MarTech:

> *O Elixir é insuperaável para orquestrar concorrência de I/O (ingestão de APIs de mídia). O Rust é perfeito para operações CPU-bound com segurança de memória. Juntos, eliminam os trade-offs de cada um isolado.*

A filosofia **Fail-Secure** e o padrão **zero `.unwrap()`** são herdados do projeto [BuildToValue](https://github.com/danzeroum), garantindo que o motor Rust nunca cause panics que derrubem a VM do Elixir.

---

*Desenvolvido por [Daniel Lau](https://github.com/danzeroum) — entusiasta de sistemas confiáveis e alto desempenho.*
