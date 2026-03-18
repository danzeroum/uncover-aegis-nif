defmodule UncoverAegisWeb.InsightsLive do
  @moduledoc """
  LiveView principal do MVP 4 — Assistente de Insights Conversacional.

  Dois modos de operacao:
  - **Modo NL** (padrao): pergunta em portugues -> Ollama -> Guardrail Rust -> Ecto
  - **Modo SQL** (demo): SQL direto -> Guardrail Rust -> Ecto (demonstra bloqueio)
  """

  use UncoverAegisWeb, :live_view

  alias UncoverAegis.Insights

  @example_questions [
    "qual o gasto total?",
    "quais campanhas tiveram mais cliques?",
    "qual a taxa de conversao?",
    "quais plataformas usamos?",
    "qual o custo por clique?",
    "quantas campanhas temos?"
  ]

  @example_sqls [
    "SELECT platform, SUM(spend) FROM campaign_metrics GROUP BY platform",
    "DELETE FROM campaign_metrics",
    "DROP TABLE campaign_metrics",
    "SELECT * FROM campaign_metrics LIMIT 3"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(UncoverAegis.PubSub, "anomalies")
    end

    {:ok,
     socket
     |> stream(:messages, [])
     |> assign(
       current_input: "",
       anomaly_alert: nil,
       loading: false,
       has_messages: false,
       sql_mode: false,
       example_questions: @example_questions,
       example_sqls: @example_sqls
     )}
  end

  # ---------------------------------------------------------------------------
  # Eventos da UI
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("send_message", %{"message" => msg}, socket) do
    msg = String.trim(msg)

    if msg == "" do
      {:noreply, socket}
    else
      user_msg = %{id: "msg-#{System.unique_integer([:positive])}", role: :user, content: msg}
      loading_msg = %{id: "msg-#{System.unique_integer([:positive])}", role: :assistant, content: nil, loading: true}

      mode = if socket.assigns.sql_mode, do: :sql, else: :nl
      send(self(), {:process_question, msg, loading_msg.id, mode})

      {:noreply,
       socket
       |> stream_insert(:messages, user_msg)
       |> stream_insert(:messages, loading_msg)
       |> assign(current_input: "", loading: true, has_messages: true)}
    end
  end

  def handle_event("use_example", %{"question" => question}, socket) do
    {:noreply, assign(socket, :current_input, question)}
  end

  def handle_event("toggle_sql_mode", _params, socket) do
    {:noreply, assign(socket, sql_mode: not socket.assigns.sql_mode, current_input: "")}
  end

  def handle_event("dismiss_alert", _params, socket) do
    {:noreply, assign(socket, :anomaly_alert, nil)}
  end

  # ---------------------------------------------------------------------------
  # Mensagens internas
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:process_question, input, loading_id, :nl}, socket) do
    response_msg =
      case Insights.ask(input) do
        {:ok, result} ->
          format_success(result)

        {:error, :llm, _reason} ->
          %{
            role: :assistant,
            content: :not_understood,
            status: :not_understood,
            icon: "\u{1F4AC}",
            example_questions: @example_questions
          }

        {:error, :guardrail, reason} ->
          %{role: :assistant, content: "\u{1F6E1}\uFE0F Guardrail bloqueou: #{reason}", status: :blocked, icon: "\u{1F534}"}

        {:error, :database, reason} ->
          %{role: :assistant, content: reason, status: :error, icon: "\u26A0\uFE0F"}
      end

    finish_response(socket, loading_id, response_msg)
  end

  def handle_info({:process_question, sql, loading_id, :sql}, socket) do
    response_msg =
      case Insights.run_safe_query(sql) do
        {:ok, result} ->
          format_success(result)

        {:unsafe_sql, reason} ->
          %{
            role: :assistant,
            content: "\u{1F6E1}\uFE0F Guardrail Rust BLOQUEOU esta query.\n\nMotivo: #{reason}",
            status: :blocked,
            icon: "\u{1F534}"
          }

        {:error, reason} ->
          %{role: :assistant, content: reason, status: :error, icon: "\u26A0\uFE0F"}
      end

    finish_response(socket, loading_id, response_msg)
  end

  # Alerta em tempo real do MVP3 via PubSub
  def handle_info({:anomaly, campaign_id, z_score}, socket) do
    alert = %{
      campaign_id: campaign_id,
      z_score: Float.round(z_score, 2),
      at: DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()
    }

    {:noreply, assign(socket, :anomaly_alert, alert)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%# Header %>
      <div class="px-6 py-4 border-b border-gray-200 bg-white rounded-t-xl shadow-sm">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold text-gray-900">\u{1F6E1}\uFE0F Uncover Aegis</h1>
            <p class="text-xs text-gray-500 mt-0.5">CMO Copilot — Insights seguros em tempo real</p>
          </div>
          <div class="flex items-center gap-3">
            <button
              phx-click="toggle_sql_mode"
              class={[
                "text-xs px-3 py-1 rounded-full border font-medium transition",
                if(@sql_mode,
                  do: "bg-orange-100 border-orange-300 text-orange-700",
                  else: "bg-gray-100 border-gray-200 text-gray-500 hover:border-gray-400"
                )
              ]}
            >
              <%= if @sql_mode, do: "\u{1F9EA} Modo SQL", else: "SQL direto" %>
            </button>
            <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
              \u2022 Guardrail Rust Ativo
            </span>
          </div>
        </div>
      </div>

      <%# Banner modo SQL %>
      <div
        :if={@sql_mode}
        class="mx-4 mt-3 p-3 bg-orange-50 border border-orange-200 rounded-lg"
      >
        <p class="text-xs text-orange-700 font-medium">
          \u{1F9EA} Modo SQL ativo — a query vai direto para o Guardrail Rust sem passar pelo LLM.
          Tente <code class="bg-orange-100 px-1 rounded">DELETE FROM campaign_metrics</code> para ver o bloqueio.
        </p>
      </div>

      <%# Alerta de anomalia do MVP3 (PubSub real-time) %>
      <div
        :if={@anomaly_alert}
        class="mx-4 mt-3 p-3 bg-red-50 border border-red-300 rounded-lg flex items-start justify-between"
      >
        <div class="flex items-start gap-2">
          <span class="text-red-500 text-lg mt-0.5">\u{1F6A8}</span>
          <div>
            <p class="text-sm font-semibold text-red-800">Sentinel — Anomalia Detectada</p>
            <p class="text-xs text-red-700 mt-0.5">
              Campanha <strong><%= @anomaly_alert.campaign_id %></strong>
              | Z-Score: <strong><%= @anomaly_alert.z_score %></strong>
              | <%= @anomaly_alert.at %> UTC
            </p>
          </div>
        </div>
        <button phx-click="dismiss_alert" class="text-red-400 hover:text-red-600 text-sm ml-2 mt-0.5">
          \u2715
        </button>
      </div>

      <%# Area de mensagens %>
      <div class="flex-1 overflow-y-auto p-4">
        <%# Tela de boas-vindas %>
        <div
          :if={not @has_messages}
          class="flex flex-col items-center justify-center h-full text-center py-12"
        >
          <div class="text-5xl mb-4"><%= if @sql_mode, do: "\u{1F9EA}", else: "\u{1F4CA}" %></div>
          <h2 class="text-lg font-semibold text-gray-700">
            <%= if @sql_mode, do: "Modo SQL — Teste o Guardrail", else: "Pronto para analisar suas campanhas" %>
          </h2>
          <p class="text-sm text-gray-500 mt-2 max-w-sm">
            <%= if @sql_mode do %>
              Envie qualquer SQL. Queries de escrita serao bloqueadas pelo motor Rust antes de tocar o banco.
            <% else %>
              Faça perguntas em português. Cada resposta é validada pelo escudo Rust antes de tocar o banco.
            <% end %>
          </p>
          <div class="mt-6 flex flex-wrap gap-2 justify-center">
            <%= if @sql_mode do %>
              <button
                :for={q <- @example_sqls}
                phx-click="use_example"
                phx-value-question={q}
                class={[
                  "text-xs border rounded-full px-3 py-1.5 transition font-mono",
                  if(String.starts_with?(q, "SELECT"),
                    do: "bg-white border-gray-200 hover:border-blue-400 hover:text-blue-600 text-gray-600",
                    else: "bg-red-50 border-red-200 hover:border-red-400 text-red-600"
                  )
                ]}
              >
                <%= q %>
              </button>
            <% else %>
              <button
                :for={q <- @example_questions}
                phx-click="use_example"
                phx-value-question={q}
                class="text-xs bg-white border border-gray-200 hover:border-blue-400 hover:text-blue-600 rounded-full px-3 py-1.5 text-gray-600 transition"
              >
                <%= q %>
              </button>
            <% end %>
          </div>
        </div>

        <%# Stream de mensagens %>
        <div id="messages" phx-update="stream" class="space-y-3">
          <div :for={{dom_id, msg} <- @streams.messages} id={dom_id} class={message_wrapper_class(msg.role)}>
            <div class={message_bubble_class(msg)}>
              <%# Loading spinner %>
              <div :if={Map.get(msg, :loading, false)} class="flex items-center gap-2">
                <svg class="animate-spin h-4 w-4 text-gray-500" viewBox="0 0 24 24" fill="none">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
                </svg>
                <span class="text-sm text-gray-500">Validando pelo escudo Rust...</span>
              </div>

              <%# Mensagem de pergunta nao entendida — com exemplos clicaveis %>
              <div :if={not Map.get(msg, :loading, false) and Map.get(msg, :content) == :not_understood}>
                <p class="text-sm text-gray-600">
                  <span class="mr-1">\u{1F4AC}</span>
                  Nao consegui gerar SQL para esta pergunta. Experimente:
                </p>
                <div class="mt-2 flex flex-wrap gap-1.5">
                  <button
                    :for={q <- Map.get(msg, :example_questions, [])}
                    phx-click="use_example"
                    phx-value-question={q}
                    class="text-xs bg-gray-100 hover:bg-blue-50 hover:text-blue-700 border border-gray-200 hover:border-blue-300 rounded-full px-2.5 py-1 transition text-gray-600"
                  >
                    <%= q %>
                  </button>
                </div>
              </div>

              <%# Mensagem normal %>
              <p :if={not Map.get(msg, :loading, false) and Map.get(msg, :content) != :not_understood} class="text-sm whitespace-pre-wrap">
                <span :if={msg[:icon]} class="mr-1"><%= msg.icon %></span><%= msg.content %>
              </p>

              <%# Metadata de observabilidade %>
              <div :if={msg[:metadata]} class="mt-2 pt-2 border-t border-gray-200 space-y-1">
                <p class="text-xs text-gray-400">
                  \u{1F7E2} Guardrail Rust: <strong><%= msg.metadata.guardrail_us %>µs</strong>
                  &nbsp;|&nbsp; Query: <strong><%= msg.metadata.query_ms %>ms</strong>
                  &nbsp;|&nbsp; <%= msg.metadata.row_count %> linha(s)
                </p>
                <p class="text-xs font-mono text-gray-400 truncate" title={msg.metadata.sql}>
                  SQL: <%= msg.metadata.sql %>
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%# Input %>
      <div class="px-4 pb-4 pt-2 bg-white border-t border-gray-100">
        <form phx-submit="send_message" class="flex gap-2">
          <input
            type="text"
            name="message"
            value={@current_input}
            placeholder={if @sql_mode, do: "ex: DELETE FROM campaign_metrics", else: "ex: qual o gasto total?"}
            autocomplete="off"
            disabled={@loading}
            class={[
              "flex-1 rounded-lg border px-4 py-2.5 text-sm focus:outline-none focus:ring-2 disabled:opacity-50",
              if(@sql_mode,
                do: "border-orange-300 focus:ring-orange-400 font-mono",
                else: "border-gray-300 focus:ring-blue-500"
              )
            ]}
          />
          <button
            type="submit"
            disabled={@loading}
            class={[
              "px-4 py-2.5 rounded-lg text-sm font-medium transition text-white disabled:opacity-50 disabled:cursor-not-allowed",
              if(@sql_mode, do: "bg-orange-500 hover:bg-orange-600", else: "bg-blue-600 hover:bg-blue-700")
            ]}
          >
            <%= if @loading, do: "...", else: if(@sql_mode, do: "Executar", else: "Perguntar") %>
          </button>
        </form>
        <p class="text-xs text-gray-400 mt-1.5 text-center">
          <%= if @sql_mode do %>
            Modo SQL: queries de escrita são bloqueadas pelo Guardrail Rust antes de tocar o banco.
          <% else %>
            Toda query é validada pelo Aegis-Rust antes de tocar o banco.
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers privados
  # ---------------------------------------------------------------------------

  defp finish_response(socket, loading_id, response_msg) do
    final_msg = Map.put(response_msg, :id, "msg-#{System.unique_integer([:positive])}")

    {:noreply,
     socket
     |> stream_delete_by_dom_id(:messages, loading_id)
     |> stream_insert(:messages, final_msg)
     |> assign(:loading, false)}
  end

  defp format_success(result) do
    content =
      if result.rows == [] do
        "Nenhum resultado encontrado para esta consulta."
      else
        result.rows
        |> Enum.map(fn row ->
          Enum.zip(result.columns, row)
          |> Enum.map_join("  |  ", fn {col, val} -> "#{col}: #{format_value(val)}" end)
        end)
        |> Enum.join("\n")
      end

    anomaly_note =
      if result[:anomaly],
        do: "\n\n\u26A0\uFE0F Anomalia estatistica detectada (Z-Score: #{Float.round(result.z_score, 2)})",
        else: ""

    %{
      role: :assistant,
      content: content <> anomaly_note,
      status: :ok,
      icon: "\u{1F4CB}",
      metadata: %{
        sql: result[:metadata][:sql] || "",
        guardrail_us: result[:metadata][:guardrail_us] || 0,
        query_ms: result[:metadata][:query_ms] || 0,
        row_count: result[:row_count] || length(result.rows)
      }
    }
  end

  defp format_value(nil), do: "—"
  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp format_value(v), do: inspect(v)

  defp message_wrapper_class(:user), do: "flex justify-end"
  defp message_wrapper_class(_), do: "flex justify-start"

  defp message_bubble_class(%{role: :user}) do
    "max-w-[75%] bg-blue-600 text-white rounded-2xl rounded-tr-sm px-4 py-2.5"
  end

  defp message_bubble_class(%{status: :blocked}) do
    "max-w-[85%] bg-red-50 border border-red-200 text-red-800 rounded-2xl rounded-tl-sm px-4 py-2.5"
  end

  defp message_bubble_class(%{status: :error}) do
    "max-w-[85%] bg-yellow-50 border border-yellow-200 text-yellow-800 rounded-2xl rounded-tl-sm px-4 py-2.5"
  end

  defp message_bubble_class(%{loading: true}) do
    "max-w-[85%] bg-gray-50 border border-gray-200 rounded-2xl rounded-tl-sm px-4 py-2.5"
  end

  defp message_bubble_class(_) do
    "max-w-[85%] bg-white border border-gray-200 text-gray-800 rounded-2xl rounded-tl-sm px-4 py-2.5 shadow-sm"
  end
end
