defmodule UncoverAegisWeb.Plugs.RequestLogger do
  @moduledoc """
  Plug de structured logging para requests da API.

  Gera um `request_id` unico por request e injeta nos logs e no header
  `X-Request-Id` da resposta. Registra metodo, path, status e duracao
  em formato estruturado, compativel com ingestao por Datadog/Loki/CloudWatch.

  Exemplo de log emitido:

      [info] method=POST path=/api/v1/insights/query status=200
             request_id=a1b2c3d4 duration_ms=312

  O `request_id` e propagado via `Logger.metadata/1` para que todos os logs
  emitidos durante o ciclo de vida do request (Insights, Native, Repo) sejam
  correlacionaveis por ID.
  """

  @behaviour Plug

  require Logger
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    request_id = generate_request_id()
    t0 = System.monotonic_time()

    # Propaga request_id para todos os logs do processo atual
    Logger.metadata(request_id: request_id)

    conn
    |> put_resp_header("x-request-id", request_id)
    |> register_before_send(fn conn ->
      duration_ms =
        System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

      Logger.info(
        "method=#{conn.method} " <>
          "path=#{conn.request_path} " <>
          "status=#{conn.status} " <>
          "request_id=#{request_id} " <>
          "duration_ms=#{duration_ms}"
      )

      conn
    end)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
