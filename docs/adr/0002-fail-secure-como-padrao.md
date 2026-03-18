# ADR-0002 — Fail-Secure como padrão universal de tratamento de erros

**Status:** Aceito  
**Data:** 2026-03-01  
**Autor:** Daniel Lau

---

## Contexto

O Uncover Aegis opera em um domínio onde erros silenciosos têm consequências graves:

- Um regex que falha ao compilar e é ignorado → PII passa sem sanitização
- Um parâmetro inválido no Adstock que é convertido silenciosamente → resultado matemático incorreto enviado ao CMO
- Um `.unwrap()` em Rust que causa panic → derruba a BEAM inteira

O padrão mais simples de implementar seria **Fail-Silent**: ignorar o erro e continuar. Isso é tecnicamente mais fácil, mas cria falsos positivos — o sistema parece funcionar enquanto entrega resultados incorretos.

---

## Decisão

Adotar **Fail-Secure** como padrão em todas as camadas:

> Se qualquer etapa do pipeline não puder garantir o resultado correto, ela retorna erro explicitamente. Nunca produz saída parcialmente correta sem sinalizar.

**Em Rust:** zero `.unwrap()`. Toda operação falível usa `match` ou `?` com retorno explícito.

```rust
// ❌ Fail-Silent (rejeitado)
let re = Regex::new(r"\b\d{3}").unwrap(); // panic derruba a BEAM

// ✅ Fail-Secure (adotado)
let re = match Regex::new(r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b") {
    Ok(re) => re,
    Err(_) => return Ok((atoms::error(), "Falha na compilacao do motor regex de CPF".to_string())),
};
```

**No Adstock:** parâmetros fora do domínio válido retornam `:error` com sentinel explícito no vetor de contribuição (`-1.0` = decay inválido, `-2.0` = alpha/K inválidos).

```rust
if !(0.0..=1.0).contains(&decay) {
    return Ok((atoms::error(), AdstockResult {
        contribution_pct: vec![-1.0], // sentinel: decay fora do intervalo [0,1]
        ...
    }));
}
```

**Em Elixir:** o módulo `Insights` sempre propaga o erro para o LiveView com mensagem legível, nunca swallowa exceções.

---

## Consequências positivas

- **Observabilidade:** erros são visíveis no `TelemetryStore` e no painel de Observabilidade
- **Confiança operacional:** o CMO vê uma mensagem de erro clara em vez de um número errado
- **Ausência de crashs da BEAM:** zero panics Rust registrados em produção
- **Testabilidade:** cada caminho de erro é testável via ExUnit sem mocks complexos

---

## Trade-offs aceitos

- **Mais código:** cada operação falível exige tratamento explícito. Aumenta o boilerplate em ~15% nos NIFs.
- **Erros visíveis ao usuário:** em vez de silenciosamente tentar novamente, o sistema expõe o erro. Considerado correto para o domínio (dados financeiros de campanha).

---

## Alternativas rejeitadas

| Alternativa | Por que rejeitada |
|-------------|-------------------|
| **Fail-Silent** | Produz resultados incorretos sem sinalização — inaceitável em dados financeiros |
| **Fail-Fast (panic)** | Derruba a BEAM inteira — afeta todos os usuários conectados via LiveView |
| **Retry automático** | Mascara erros sistemáticos; adequado para falhas transitórias de rede, não para erros de domínio |
