# ADR-0005 — Adstock MMM em Rust NIF para interatividade em tempo real

**Status:** Aceito  
**Data:** 2026-03-15  
**Autor:** Daniel Lau

---

## Contexto

O MVP 4 introduz **Marketing Mix Modeling (MMM)** com o algoritmo Adstock (Broadbent, 1979) e saturação Hill. O modelo é exposto via sliders interativos no LiveView — o usuário arrasta `decay` e `alpha` e espera ver o gráfico recalcular em tempo real.

O algoritmo envolve:
1. **Loop iterativo** de carry-over: `adstock[t] = spend[t] + decay × adstock[t-1]` — cada período depende do anterior
2. **Exponenciação** por período para a curva Hill: `x^alpha / (x^alpha + K^alpha)`
3. **Normalização** para percentuais de contribuição

Com campanhas de 30–90 dias de histórico, são 30–90 iterações por recalculo. Cada movimento de slider dispara um evento LiveView que precisa de resposta em <100ms para parecer fluido.

---

## Decisão

Implementar `calculate_adstock` como **Rust NIF com `schedule = "DirtyCpu"`**, consistente com `ADR-0001`.

```rust
// Passo 1: carry-over geométrico (Adstock clássico de Broadbent, 1979)
let mut prev: f64 = 0.0;
for &spend in &spends {
    let current = spend + decay * prev;
    adstock_values.push(current);
    prev = current;
}

// Passo 2: saturação Hill — transforma adstock em impacto (0.0–1.0)
let k_alpha = half_saturation.powf(alpha);
let saturated: Vec<f64> = adstock_values.iter().map(|&x| {
    let x_alpha = x.powf(alpha);
    x_alpha / (x_alpha + k_alpha)
}).collect();
```

O resultado é serializado automaticamente pelo Rustler via `NifStruct` — sem serialização manual:

```rust
#[derive(rustler::NifStruct)]
#[module = "UncoverAegis.Native.AdstockResult"]
pub struct AdstockResult {
    pub adstock_values: Vec<f64>,
    pub saturated_values: Vec<f64>,
    pub contribution_pct: Vec<f64>,
}
```

---

## Consequências positivas

- **Latência <1ms** para campanhas de até 365 dias — sliders respondem em tempo real
- **WebSocket não bloqueia:** o LiveView continua recebendo eventos de outros usuários durante o cálculo
- **Sem dependências Python/R:** MMM roda no mesmo processo Elixir, sem subprocess ou HTTP
- **Extensível:** adicionar modelos como Weibull decay ou Logistic saturation é trocar ~5 linhas Rust

---

## Trade-offs aceitos

- **Mesmo trade-off de toolchain do ADR-0001:** Rust obrigatório no ambiente de build
- **Modelo simplificado:** Adstock geométrico + Hill é suficiente para demonstração de MMM. Modelos de produção (Robyn, Meridian) exigem séries temporais muito maiores e validação estatística cross-validation
- **Half-saturation via mediana:** `K` é estimado como a mediana dos spends da campanha — heurística razoável para PoC, mas em produção deve ser calibrado com regressão bayesiana

---

## Alternativas rejeitadas

| Alternativa | Por que rejeitada |
|-------------|-------------------|
| **Elixir puro com `Enum.reduce`** | Loop iterativo em Elixir é ~50× mais lento; sliders teriam latência perceptível com séries longas |
| **Python via Port (numpy/scipy)** | Overhead de subprocess + serialização: ~10ms de latência mínima vs <1ms com NIF |
| **Pré-calcular todos os cenários** | Espaço de parâmetros contínuo (decay 0–1, alpha 0.5–5) torna o cache inviável |
| **JavaScript no frontend** | Eliminaria a NIF Rust, mas moveria lógica crítica de negócio para o cliente — inaceitável |
