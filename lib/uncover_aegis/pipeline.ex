defmodule UncoverAegis.Pipeline do
  @moduledoc """
  Pipeline de ingestão concorrente de dados de campanhas de marketing.

  ## Arquitetura

  ```
  Lista de textos brutos
       |
       v
  Task.async_stream  ←— Elixir/OTP: concorrência massiva (I/O-bound)
       |
       v
  Native.sanitize_and_validate/1  ←— Rust via NIF: CPU-bound (PII + Injection)
       |
       v
  {:ok | :threat_detected | :error, payload}
       |
       v
  enviar_para_llm/1  (quando :ok)
  ```

  A filosofia "Let it crash" do OTP garante que uma falha em um
  processo não derruba os outros. O Supervisor reinicia processos
  falhos automaticamente.
  """

  alias UncoverAegis.Native

  @doc """
  Processa uma lista de textos de campanha em paralelo.

  Cada texto passa pelo motor Rust (sanitização + validação) e,
  se aprovado, é encaminhado para o LLM.

  O número máximo de processos concorrentes é `System.schedulers_online/0`,
  aproveitando todos os núcleos disponíveis da máquina.

  ## Retorno
  Lista de tuplas `{status, payload}` na mesma ordem da entrada.

  ## Exemplo

      iex> UncoverAegis.Pipeline.process_campaigns([
      ...>   "CPF 123.456.789-00 do cliente",
      ...>   "Campanha normal"
      ...> ])
      [{:ok, "[LLM] CPF [CPF_REDACTED] do cliente"}, {:ok, "[LLM] Campanha normal"}]

  """
  @spec process_campaigns([String.t()]) :: [{:ok | :error | :threat_detected, String.t()}]
  def process_campaigns(texts) when is_list(texts) do
    texts
    |> Task.async_stream(
      &process_single/1,
      max_concurrency: System.schedulers_online(),
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, "Processo encerrado: #{inspect(reason)}"}
    end)
  end

  # Processa um único texto: delega sanitização para o Rust e decide destino.
  defp process_single(text) do
    case Native.sanitize_and_validate(text) do
      {:ok, clean_text} ->
        result = enviar_para_llm(clean_text)
        {:ok, result}

      {:threat_detected, reason} ->
        registrar_alerta(reason)
        {:threat_detected, "[BLOQUEADO] #{reason}"}

      {:error, reason} ->
        # Fail-Secure: em caso de erro interno, não processa o dado.
        {:error, "Motor indisponível: #{reason}"}
    end
  end

  # Simula o envio para um LLM (OpenAI/Gemini).
  # Em produção: substituir por chamada HTTP via Req/Finch.
  defp enviar_para_llm(text), do: "[LLM] #{text}"

  # Registra alertas de segurança.
  # Em produção: integrar com sistema de alertas (PagerDuty, etc.)
  defp registrar_alerta(reason) do
    require Logger
    Logger.warning("[AEGIS ALERT] Prompt injection bloqueado: #{reason}")
  end
end
