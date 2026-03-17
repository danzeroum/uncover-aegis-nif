defmodule UncoverAegisWeb.Api.HealthController do
  @moduledoc """
  Health check endpoint para monitoramento e observabilidade.

  GET /api/health

  Verifica o status de cada subsistema critico:
  - banco de dados (Ecto/SQLite)
  - guardrail Rust (NIF carregado)
  - LLM (Ollama acessivel)

  Retorna HTTP 200 se todos os sistemas criticos estao operacionais,
  HTTP 503 se algum subsistema critico falhou.

  Exemplo de resposta saudavel:

      {
        "status": "ok",
        "version": "0.3.0",
        "checks": {
          "database": {"status": "ok", "latency_ms": 1},
          "guardrail_rust": {"status": "ok", "latency_us": 4},
          "llm": {"status": "ok", "model": "qwen2.5-coder:7b"}
        }
      }
  """

  use UncoverAegisWeb, :controller

  alias UncoverAegis.{Native, Repo}

  def index(conn, _params) do
    checks = %{
      database: check_database(),
      guardrail_rust: check_guardrail(),
      llm: check_llm()
    }

    all_ok = Enum.all?(checks, fn {_, v} -> v[:status] == "ok" end)
    http_status = if all_ok, do: 200, else: 503

    conn
    |> put_status(http_status)
    |> json(%{
      status: if(all_ok, do: "ok", else: "degraded"),
      version: Application.spec(:uncover_aegis, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: checks
    })
  end

  # ---------------------------------------------------------------------------
  # Checks individuais
  # ---------------------------------------------------------------------------

  defp check_database do
    t0 = System.monotonic_time()

    result =
      case Repo.query("SELECT 1") do
        {:ok, _} -> %{status: "ok"}
        {:error, e} -> %{status: "error", detail: inspect(e)}
      end

    latency_ms = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)
    Map.put(result, :latency_ms, latency_ms)
  end

  defp check_guardrail do
    t0 = System.monotonic_time()

    result =
      case Native.validate_read_only_sql("SELECT 1") do
        {:ok, _} -> %{status: "ok"}
        _ -> %{status: "error", detail: "NIF nao respondeu como esperado"}
      end

    latency_us = System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)
    Map.put(result, :latency_us, latency_us)
  end

  defp check_llm do
    # Testa conectividade TCP na porta do Ollama sem fazer inferencia
    case :gen_tcp.connect(~c"localhost", 11434, [:binary, active: false], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        %{status: "ok", model: "qwen2.5-coder:7b", note: "TCP reachable"}

      {:error, :econnrefused} ->
        %{status: "unavailable", detail: "Ollama nao esta rodando (fallback LlmMock ativo)"}

      {:error, reason} ->
        %{status: "error", detail: inspect(reason)}
    end
  end
end
