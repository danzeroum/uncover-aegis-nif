defmodule UncoverAegis do
  @moduledoc """
  Uncover Aegis — Motor híbrido de sanitização de dados para pipelines de IA Generativa.

  ## Visão Geral

  Este projeto implementa uma arquitetura que combina:
  - **Elixir/OTP**: orquestração concorrente massiva (I/O-bound), tolerância a falhas via Supervisors.
  - **Rust via Rustler (NIFs)**: sanitização de PII e detecção de Prompt Injection (CPU-bound),
    executado em Dirty NIFs para não bloquear os schedulers da BEAM.

  ## Uso

      iex> UncoverAegis.Pipeline.process_campaigns([
      ...>   "Cliente CPF 123.456.789-00 gastou R$ 100",
      ...>   "Campanha sem dados sensíveis"
      ...> ])
      [{:ok, "Cliente CPF [REDACTED] gastou R$ 100"}, {:ok, "Campanha sem dados sensíveis"}]

  """
end
