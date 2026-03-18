defmodule UncoverAegis.TelemetryStore do
  @moduledoc """
  Agent que mantém uma janela deslizante de até 100 eventos de
  telemetria do pipeline Insights (guardrail, query, LLM).

  Persiste apenas em memória — reset ao reiniciar o servidor.
  Intencionalmente simples: sem banco, sem ETS, sem overhead.

  ## Evento
  %{
    id:           integer,
    at:           DateTime,
    question:     string,
    sql:          string,
    guardrail_us: integer,   # microsegundos NIF Rust
    query_ms:     integer,   # milissegundos Ecto
    llm_ms:       integer,   # estimado (futuro)
    blocked:      boolean,
    status:       :ok | :blocked | :error
  }
  """

  use Agent

  @max_entries 100

  def start_link(_opts) do
    Agent.start_link(fn -> %{events: [], blocked_count: 0} end, name: __MODULE__)
  end

  @doc "Registra um evento de telemetria."
  def record(attrs) when is_map(attrs) do
    event = Map.merge(
      %{id: System.unique_integer([:positive, :monotonic]),
        at: DateTime.utc_now(),
        question: "",
        sql: "",
        guardrail_us: 0,
        query_ms: 0,
        llm_ms: 0,
        blocked: false,
        status: :ok},
      attrs
    )

    Agent.update(__MODULE__, fn state ->
      events = [event | state.events] |> Enum.take(@max_entries)
      blocked_count = if event.blocked, do: state.blocked_count + 1, else: state.blocked_count
      %{state | events: events, blocked_count: blocked_count}
    end)

    # Notifica LiveViews que estão na aba de observabilidade
    Phoenix.PubSub.broadcast(UncoverAegis.PubSub, "telemetry", {:new_event, event})
  end

  @doc "Retorna os N eventos mais recentes (padrao 20)."
  def recent(n \\ 20) do
    Agent.get(__MODULE__, fn state -> Enum.take(state.events, n) end)
  end

  @doc "Retorna estatísticas agregadas."
  def stats do
    Agent.get(__MODULE__, fn state ->
      events = state.events
      ok_events = Enum.filter(events, &(&1.status == :ok))

      avg_guardrail =
        if ok_events == [], do: 0,
        else: round(Enum.sum(Enum.map(ok_events, & &1.guardrail_us)) / length(ok_events))

      avg_query =
        if ok_events == [], do: 0,
        else: round(Enum.sum(Enum.map(ok_events, & &1.query_ms)) / length(ok_events))

      %{
        total: length(events),
        blocked_count: state.blocked_count,
        avg_guardrail_us: avg_guardrail,
        avg_query_ms: avg_query
      }
    end)
  end
end
