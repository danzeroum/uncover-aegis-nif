defmodule UncoverAegisWeb.InsightsLive do
  @moduledoc """
  LiveView principal — CMO Copilot com 4 abas:
    - Insights:        chat NL→SQL com guardrail Rust
    - Campanhas:       tabela de KPIs + cards resumo
    - Mix de Mídia:   Adstock MMM via NIF Rust + gráficos Chart.js
    - Observabilidade: telemetria em tempo real (latencias, bloqueios, log SQL)
    - Sentinel:        log de anomalias em tempo real (Z-Score)
  """

  use UncoverAegisWeb, :live_view

  alias UncoverAegis.{Insights, Repo, Native, TelemetryStore}
  import Ecto.Query

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

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(UncoverAegis.PubSub, "anomalies")
      Phoenix.PubSub.subscribe(UncoverAegis.PubSub, "telemetry")
    end

    campaigns = load_campaigns()
    kpis = compute_kpis(campaigns)
    mmm_campaigns = load_mmm_campaigns()
    tele_events = TelemetryStore.recent(20)
    tele_stats = TelemetryStore.stats()

    {:ok,
     socket
     |> stream(:messages, [])
     |> assign(
       active_tab: :insights,
       current_input: "",
       loading: false,
       has_messages: false,
       sql_mode: false,
       example_questions: @example_questions,
       example_sqls: @example_sqls,
       # Campanhas
       campaigns: campaigns,
       kpis: kpis,
       platform_filter: "all",
       # MMM
       mmm_campaigns: mmm_campaigns,
       mmm_selected: get_first_campaign(mmm_campaigns),
       mmm_decay: 0.7,
       mmm_alpha: 2.0,
       mmm_result: nil,
       mmm_loading: false,
       # Observabilidade
       tele_events: tele_events,
       tele_stats: tele_stats,
       # Sentinel
       anomaly_alerts: [],
       anomaly_count: 0
     )}
  end

  # ---------------------------------------------------------------------------
  # Eventos
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("filter_platform", %{"platform" => platform}, socket) do
    campaigns = load_campaigns(platform)
    kpis = compute_kpis(campaigns)
    {:noreply, assign(socket, campaigns: campaigns, kpis: kpis, platform_filter: platform)}
  end

  def handle_event("mmm_select_campaign", %{"campaign" => campaign_id}, socket) do
    {:noreply, assign(socket, mmm_selected: campaign_id, mmm_result: nil)}
  end

  def handle_event("mmm_decay", %{"value" => v}, socket) do
    {:noreply, assign(socket, mmm_decay: parse_slider(v, 0.7), mmm_result: nil)}
  end

  def handle_event("mmm_alpha", %{"value" => v}, socket) do
    {:noreply, assign(socket, mmm_alpha: parse_slider(v, 2.0), mmm_result: nil)}
  end

  def handle_event("mmm_calculate", _params, socket) do
    send(self(), {:run_adstock, socket.assigns.mmm_selected, socket.assigns.mmm_decay, socket.assigns.mmm_alpha})
    {:noreply, assign(socket, mmm_loading: true)}
  end

  def handle_event("dismiss_alert", %{"id" => id}, socket) do
    alerts = Enum.reject(socket.assigns.anomaly_alerts, &(&1.id == id))
    {:noreply, assign(socket, anomaly_alerts: alerts, anomaly_count: length(alerts))}
  end

  def handle_event("copy_sql", %{"sql" => sql}, socket) do
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: sql})}
  end

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
    {:noreply, assign(socket, current_input: question)}
  end

  def handle_event("toggle_sql_mode", _params, socket) do
    {:noreply, assign(socket, sql_mode: not socket.assigns.sql_mode, current_input: "")}
  end

  # ---------------------------------------------------------------------------
  # handle_info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:run_adstock, campaign_id, decay, alpha}, socket) do
    spends = load_campaign_spends(campaign_id)
    dates  = load_campaign_dates(campaign_id)
    half_sat = median(spends)
    result =
      case Native.calculate_adstock(spends, decay, alpha, half_sat) do
        {:ok, r} ->
          %{campaign_id: campaign_id, dates: dates, spends: spends,
            adstock_values: r.adstock_values, saturated_values: r.saturated_values,
            contribution_pct: r.contribution_pct, decay: decay, alpha: alpha, half_saturation: half_sat}
        _ -> nil
      end
    socket = socket |> assign(mmm_result: result, mmm_loading: false) |> maybe_push_chart_event(result, dates)
    {:noreply, socket}
  end

  def handle_info({:process_question, input, loading_id, :nl}, socket) do
    response_msg =
      case Insights.ask(input) do
        {:ok, result} ->
          TelemetryStore.record(%{
            question: input,
            sql: result.metadata.sql,
            guardrail_us: result.metadata.guardrail_us,
            query_ms: result.metadata.query_ms,
            blocked: false,
            status: :ok
          })
          format_success(result)
        {:error, :llm, _} ->
          TelemetryStore.record(%{question: input, status: :error, blocked: false})
          %{role: :assistant, content: :not_understood, status: :not_understood,
            icon: "💬", example_questions: @example_questions}
        {:error, :guardrail, reason} ->
          TelemetryStore.record(%{question: input, status: :blocked, blocked: true})
          %{role: :assistant, content: "🛡️ Guardrail bloqueou: #{reason}", status: :blocked, icon: "🔴"}
        {:error, :database, reason} ->
          TelemetryStore.record(%{question: input, status: :error, blocked: false})
          %{role: :assistant, content: reason, status: :error, icon: "⚠️"}
      end
    finish_response(socket, loading_id, response_msg)
  end

  def handle_info({:process_question, sql, loading_id, :sql}, socket) do
    response_msg =
      case Insights.run_safe_query(sql) do
        {:ok, result} ->
          TelemetryStore.record(%{question: "[SQL direto]", sql: sql, status: :ok, blocked: false})
          format_success(result)
        {:unsafe_sql, reason} ->
          TelemetryStore.record(%{question: "[SQL direto]", sql: sql, status: :blocked, blocked: true})
          %{role: :assistant,
            content: "🛡️ Guardrail Rust BLOQUEOU esta query.\n\nMotivo: #{reason}",
            status: :blocked, icon: "🔴"}
        {:error, reason} ->
          TelemetryStore.record(%{question: "[SQL direto]", sql: sql, status: :error, blocked: false})
          %{role: :assistant, content: reason, status: :error, icon: "⚠️"}
      end
    finish_response(socket, loading_id, response_msg)
  end

  def handle_info({:anomaly, campaign_id, z_score}, socket) do
    alert = %{
      id: "alert-#{System.unique_integer([:positive])}",
      campaign_id: campaign_id,
      z_score: Float.round(z_score, 2),
      severity: if(abs(z_score) > 4.0, do: :critical, else: :warning),
      at: DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()
    }
    alerts = [alert | socket.assigns.anomaly_alerts] |> Enum.take(20)
    {:noreply, assign(socket, anomaly_alerts: alerts, anomaly_count: length(alerts))}
  end

  def handle_info({:new_event, _event}, socket) do
    tele_events = TelemetryStore.recent(20)
    tele_stats  = TelemetryStore.stats()
    {:noreply, assign(socket, tele_events: tele_events, tele_stats: tele_stats)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%!-- HEADER --%>
      <div class="px-6 py-4 border-b border-gray-200 bg-white shadow-sm">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold text-gray-900">🛡️ Uncover Aegis</h1>
            <p class="text-xs text-gray-500 mt-0.5">CMO Copilot — Insights seguros em tempo real</p>
          </div>
          <div class="flex items-center gap-2">
            <span :if={@tele_stats.avg_guardrail_us > 0}
              class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-purple-100 text-purple-800">
              ⚡ <%= @tele_stats.avg_guardrail_us %>µs
            </span>
            <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
              • Guardrail Rust Ativo
            </span>
          </div>
        </div>

        <%!-- ABAS --%>
        <div class="flex gap-1 mt-4 border-b border-gray-100 overflow-x-auto">
          <button phx-click="switch_tab" phx-value-tab="insights" class={tab_class(@active_tab == :insights)}>📊 Insights</button>
          <button phx-click="switch_tab" phx-value-tab="campaigns" class={tab_class(@active_tab == :campaigns)}>📋 Campanhas</button>
          <button phx-click="switch_tab" phx-value-tab="mmm" class={tab_class(@active_tab == :mmm)}>🧪 Mix de Mídia</button>
          <button phx-click="switch_tab" phx-value-tab="observability" class={tab_class(@active_tab == :observability)}>
            🔍 Observabilidade
            <span :if={@tele_stats.blocked_count > 0}
              class="ml-1.5 inline-flex items-center justify-center w-4 h-4 text-xs font-bold bg-orange-500 text-white rounded-full">
              <%= @tele_stats.blocked_count %>
            </span>
          </button>
          <button phx-click="switch_tab" phx-value-tab="sentinel" class={tab_class(@active_tab == :sentinel)}>
            🚨 Sentinel
            <span :if={@anomaly_count > 0}
              class="ml-1.5 inline-flex items-center justify-center w-4 h-4 text-xs font-bold bg-red-500 text-white rounded-full">
              <%= @anomaly_count %>
            </span>
          </button>
        </div>
      </div>

      <%!-- CONTEÚDO --%>
      <div class="flex-1 overflow-y-auto">

        <%!-- ABA: INSIGHTS --%>
        <div :if={@active_tab == :insights} class="flex flex-col h-full">
          <div :if={@sql_mode} class="mx-4 mt-3 p-3 bg-orange-50 border border-orange-200 rounded-lg">
            <p class="text-xs text-orange-700 font-medium">
              🧪 Modo SQL ativo — a query vai direto para o Guardrail Rust sem passar pelo LLM.
              Tente <code class="bg-orange-100 px-1 rounded">DELETE FROM campaign_metrics</code>.
            </p>
          </div>
          <div class="flex-1 overflow-y-auto p-4">
            <div :if={not @has_messages} class="flex flex-col items-center justify-center h-full text-center py-12">
              <div class="text-5xl mb-4"><%= if @sql_mode, do: "🧪", else: "📊" %></div>
              <h2 class="text-lg font-semibold text-gray-700">
                <%= if @sql_mode, do: "Modo SQL — Teste o Guardrail", else: "Pronto para analisar suas campanhas" %>
              </h2>
              <p class="text-sm text-gray-500 mt-2 max-w-sm">
                <%= if @sql_mode, do: "Envie qualquer SQL. Queries de escrita serao bloqueadas pelo motor Rust.", else: "Faça perguntas em português. Cada resposta é validada pelo escudo Rust." %>
              </p>
              <div class="mt-6 flex flex-wrap gap-2 justify-center">
                <%= if @sql_mode do %>
                  <button :for={q <- @example_sqls} phx-click="use_example" phx-value-question={q}
                    class={["text-xs border rounded-full px-3 py-1.5 transition font-mono",
                      if(String.starts_with?(q, "SELECT"),
                        do: "bg-white border-gray-200 hover:border-blue-400 hover:text-blue-600 text-gray-600",
                        else: "bg-red-50 border-red-200 hover:border-red-400 text-red-600")]}>
                    <%= q %>
                  </button>
                <% else %>
                  <button :for={q <- @example_questions} phx-click="use_example" phx-value-question={q}
                    class="text-xs bg-white border border-gray-200 hover:border-blue-400 hover:text-blue-600 rounded-full px-3 py-1.5 text-gray-600 transition">
                    <%= q %>
                  </button>
                <% end %>
              </div>
            </div>
            <div id="messages" phx-update="stream" class="space-y-3">
              <div :for={{dom_id, msg} <- @streams.messages} id={dom_id} class={message_wrapper_class(msg.role)}>
                <div class={message_bubble_class(msg)}>
                  <div :if={Map.get(msg, :loading, false)} class="flex items-center gap-2">
                    <svg class="animate-spin h-4 w-4 text-gray-500" viewBox="0 0 24 24" fill="none">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
                    </svg>
                    <span class="text-sm text-gray-500">Validando pelo escudo Rust...</span>
                  </div>
                  <div :if={not Map.get(msg, :loading, false) and Map.get(msg, :content) == :not_understood}>
                    <p class="text-sm text-gray-600"><span class="mr-1">💬</span>Nao consegui gerar SQL. Experimente:</p>
                    <div class="mt-2 flex flex-wrap gap-1.5">
                      <button :for={q <- Map.get(msg, :example_questions, [])} phx-click="use_example" phx-value-question={q}
                        class="text-xs bg-gray-100 hover:bg-blue-50 hover:text-blue-700 border border-gray-200 hover:border-blue-300 rounded-full px-2.5 py-1 transition text-gray-600">
                        <%= q %>
                      </button>
                    </div>
                  </div>
                  <p :if={not Map.get(msg, :loading, false) and Map.get(msg, :content) != :not_understood} class="text-sm whitespace-pre-wrap">
                    <span :if={msg[:icon]} class="mr-1"><%= msg.icon %></span><%= msg.content %>
                  </p>
                  <div :if={msg[:metadata]} class="mt-2 pt-2 border-t border-gray-200 space-y-1">
                    <p class="text-xs text-gray-400">
                      🟢 Guardrail Rust: <strong><%= msg.metadata.guardrail_us %>µs</strong>
                      &nbsp;|&nbsp; Query: <strong><%= msg.metadata.query_ms %>ms</strong>
                      &nbsp;|&nbsp; <%= msg.metadata.row_count %> linha(s)
                    </p>
                    <p class="text-xs font-mono text-gray-400 truncate" title={msg.metadata.sql}>SQL: <%= msg.metadata.sql %></p>
                  </div>
                </div>
              </div>
            </div>
          </div>
          <div class="px-4 pb-4 pt-2 bg-white border-t border-gray-100">
            <div class="flex items-center justify-between mb-2">
              <button phx-click="toggle_sql_mode"
                class={["text-xs px-3 py-1 rounded-full border font-medium transition",
                  if(@sql_mode, do: "bg-orange-100 border-orange-300 text-orange-700", else: "bg-gray-100 border-gray-200 text-gray-500 hover:border-gray-400")]}>
                <%= if @sql_mode, do: "🧪 Modo SQL", else: "SQL direto" %>
              </button>
            </div>
            <form phx-submit="send_message" class="flex gap-2">
              <input type="text" name="message" value={@current_input}
                placeholder={if @sql_mode, do: "ex: DELETE FROM campaign_metrics", else: "ex: qual o gasto total?"}
                autocomplete="off" disabled={@loading}
                class={["flex-1 rounded-lg border px-4 py-2.5 text-sm focus:outline-none focus:ring-2 disabled:opacity-50",
                  if(@sql_mode, do: "border-orange-300 focus:ring-orange-400 font-mono", else: "border-gray-300 focus:ring-blue-500")]}/>
              <button type="submit" disabled={@loading}
                class={["px-4 py-2.5 rounded-lg text-sm font-medium transition text-white disabled:opacity-50 disabled:cursor-not-allowed",
                  if(@sql_mode, do: "bg-orange-500 hover:bg-orange-600", else: "bg-blue-600 hover:bg-blue-700")]}>
                <%= if @loading, do: "...", else: if(@sql_mode, do: "Executar", else: "Perguntar") %>
              </button>
            </form>
          </div>
        </div>

        <%!-- ABA: CAMPANHAS --%>
        <div :if={@active_tab == :campaigns} class="p-6">
          <div class="grid grid-cols-2 gap-4 mb-6 sm:grid-cols-4">
            <.kpi_card title="Gasto Total" value={"R$ #{format_brl(@kpis.total_spend)}"} sub="todos os canais" color="blue" icon="💰" />
            <.kpi_card title="Cliques" value={format_number(@kpis.total_clicks)} sub="acumulado" color="green" icon="🤝" />
            <.kpi_card title="Conversões" value={format_number(@kpis.total_conversions)} sub="acumulado" color="purple" icon="✅" />
            <.kpi_card title="CPC Médio" value={"R$ #{:erlang.float_to_binary(@kpis.avg_cpc + 0.0, decimals: 2)}"} sub="custo por clique" color="orange" icon="🎯" />
          </div>
          <div class="flex items-center gap-2 mb-4">
            <span class="text-sm text-gray-500 font-medium">Plataforma:</span>
            <button :for={p <- ["all", "google", "meta", "tiktok", "linkedin"]}
              phx-click="filter_platform" phx-value-platform={p}
              class={["text-xs px-3 py-1 rounded-full border transition capitalize",
                if(@platform_filter == p, do: "bg-blue-600 border-blue-600 text-white", else: "bg-white border-gray-200 text-gray-600 hover:border-blue-400")]}>
              <%= platform_label(p) %>
            </button>
          </div>
          <div class="bg-white rounded-xl border border-gray-200 overflow-hidden shadow-sm">
            <table class="w-full text-sm">
              <thead class="bg-gray-50 border-b border-gray-200">
                <tr>
                  <th class="text-left px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">Campanha</th>
                  <th class="text-left px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">Plataforma</th>
                  <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">Gasto</th>
                  <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">Cliques</th>
                  <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">Conversões</th>
                  <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">CPC</th>
                  <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">CPA</th>
                  <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide">CVR</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={row <- @campaigns} class="hover:bg-gray-50 transition">
                  <td class="px-4 py-3 font-medium text-gray-800"><%= row.campaign_id %></td>
                  <td class="px-4 py-3"><span class={platform_badge_class(row.platform)}><%= String.capitalize(row.platform) %></span></td>
                  <td class="px-4 py-3 text-right text-gray-700">R$ <%= format_brl(row.spend) %></td>
                  <td class="px-4 py-3 text-right text-gray-700"><%= format_number(row.clicks) %></td>
                  <td class="px-4 py-3 text-right text-gray-700"><%= format_number(row.conversions) %></td>
                  <td class="px-4 py-3 text-right font-mono text-gray-700">R$ <%= :erlang.float_to_binary(row.cpc + 0.0, decimals: 2) %></td>
                  <td class="px-4 py-3 text-right font-mono text-gray-700">R$ <%= :erlang.float_to_binary(row.cpa + 0.0, decimals: 2) %></td>
                  <td class="px-4 py-3 text-right"><span class={cvr_badge_class(row.cvr)}><%= :erlang.float_to_binary(row.cvr * 100, decimals: 1) %>%</span></td>
                </tr>
                <tr :if={@campaigns == []}>
                  <td colspan="8" class="px-4 py-8 text-center text-gray-400 text-sm">Nenhuma campanha encontrada.</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="text-xs text-gray-400 mt-3 text-center">CPC = Gasto / Cliques &nbsp;|&nbsp; CPA = Gasto / Conversões &nbsp;|&nbsp; CVR = Conversões / Cliques</p>
        </div>

        <%!-- ABA: MIX DE MÍDIA --%>
        <div :if={@active_tab == :mmm} class="p-6">
          <div class="mb-6">
            <h2 class="text-lg font-bold text-gray-900">🧪 Mix de Mídia — Adstock MMM</h2>
            <p class="text-sm text-gray-500 mt-0.5">
              Powered by NIF Rust <code class="bg-gray-100 px-1 rounded text-xs">calculate_adstock</code>.
              Visualize o impacto acumulado de cada campanha e como a verba satura ao longo do tempo.
            </p>
          </div>
          <div class="bg-white rounded-xl border border-gray-200 p-5 mb-6 shadow-sm">
            <div class="grid grid-cols-1 gap-5 sm:grid-cols-3">
              <div>
                <label class="block text-xs font-semibold text-gray-600 uppercase tracking-wide mb-2">Campanha</label>
                <div class="flex flex-col gap-1">
                  <button :for={c <- @mmm_campaigns} phx-click="mmm_select_campaign" phx-value-campaign={c}
                    class={["text-xs px-3 py-1.5 rounded-lg border text-left transition",
                      if(@mmm_selected == c, do: "bg-blue-600 border-blue-600 text-white font-semibold", else: "bg-white border-gray-200 text-gray-600 hover:border-blue-400")]}>
                    <%= c %>
                  </button>
                </div>
              </div>
              <div>
                <label class="block text-xs font-semibold text-gray-600 uppercase tracking-wide mb-1">Carry-over (Decay)</label>
                <p class="text-xs text-gray-400 mb-3">Quanto do efeito de hoje persiste amanhã. <strong>0.7 = digital</strong> | 0.9 = TV/offline</p>
                <input type="range" min="0" max="1" step="0.05" value={@mmm_decay} phx-change="mmm_decay" name="value" class="w-full accent-blue-600" />
                <div class="flex justify-between text-xs text-gray-400 mt-1">
                  <span>0</span><span class="font-bold text-blue-600"><%= @mmm_decay %></span><span>1.0</span>
                </div>
              </div>
              <div>
                <label class="block text-xs font-semibold text-gray-600 uppercase tracking-wide mb-1">Curva de Saturação (α Hill)</label>
                <p class="text-xs text-gray-400 mb-3">Velocidade dos retornos decrescentes. <strong>α=2 = curva em S</strong></p>
                <input type="range" min="0.5" max="5" step="0.5" value={@mmm_alpha} phx-change="mmm_alpha" name="value" class="w-full accent-green-600" />
                <div class="flex justify-between text-xs text-gray-400 mt-1">
                  <span>0.5</span><span class="font-bold text-green-600">α = <%= @mmm_alpha %></span><span>5.0</span>
                </div>
              </div>
            </div>
            <div class="mt-5 flex justify-end">
              <button phx-click="mmm_calculate" disabled={@mmm_loading or is_nil(@mmm_selected)}
                class="px-5 py-2.5 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold rounded-lg transition disabled:opacity-50 disabled:cursor-not-allowed">
                <%= if @mmm_loading, do: "⏳ Calculando...", else: "▶️ Calcular Adstock" %>
              </button>
            </div>
          </div>
          <div :if={@mmm_result}>
            <div class="bg-blue-50 border border-blue-200 rounded-xl p-4 mb-5">
              <p class="text-sm font-bold text-blue-800 mb-1">💡 Interpretação</p>
              <p class="text-sm text-blue-700">
                A campanha <strong><%= @mmm_result.campaign_id %></strong> gerou um impacto acumulado (Adstock) de
                <strong>R$ <%= format_brl(List.last(@mmm_result.adstock_values)) %></strong>
                no último período, contra um gasto real de <strong>R$ <%= format_brl(List.last(@mmm_result.spends)) %></strong>.
                O período de maior contribuição respondeu por
                <strong><%= @mmm_result.contribution_pct |> Enum.max() |> :erlang.float_to_binary(decimals: 1) %>%</strong> do impacto total saturado.
              </p>
            </div>
            <div class="grid grid-cols-1 gap-5 sm:grid-cols-2">
              <div class="bg-white rounded-xl border border-gray-200 p-4 shadow-sm">
                <h3 class="text-sm font-semibold text-gray-700 mb-3">Gasto Real vs. Impacto Acumulado</h3>
                <div class="h-56"><canvas id="adstock-bar" phx-hook="AdstockBar"></canvas></div>
              </div>
              <div class="bg-white rounded-xl border border-gray-200 p-4 shadow-sm">
                <h3 class="text-sm font-semibold text-gray-700 mb-3">Contribuição por Período</h3>
                <div class="h-56"><canvas id="contrib-donut" phx-hook="ContribDonut"></canvas></div>
              </div>
            </div>
            <div class="mt-5 bg-white rounded-xl border border-gray-200 overflow-hidden shadow-sm">
              <table class="w-full text-sm">
                <thead class="bg-gray-50 border-b border-gray-200">
                  <tr>
                    <th class="text-left px-4 py-3 text-xs font-semibold text-gray-500 uppercase">Data</th>
                    <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase">Gasto Real</th>
                    <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase">Adstock</th>
                    <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase">Saturação</th>
                    <th class="text-right px-4 py-3 text-xs font-semibold text-gray-500 uppercase">Contribuição</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :for={{íx, i} <- Enum.with_index(@mmm_result.spends)} class="hover:bg-gray-50">
                    <td class="px-4 py-2 text-gray-600"><%= Enum.at(@mmm_result.dates, i) |> format_date() %></td>
                    <td class="px-4 py-2 text-right text-gray-700">R$ <%= format_brl(íx) %></td>
                    <td class="px-4 py-2 text-right font-mono text-green-700">R$ <%= Enum.at(@mmm_result.adstock_values, i) |> :erlang.float_to_binary(decimals: 0) %></td>
                    <td class="px-4 py-2 text-right">
                      <span class={saturation_badge(Enum.at(@mmm_result.saturated_values, i))}>
                        <%= Enum.at(@mmm_result.saturated_values, i) |> Kernel.*(100) |> :erlang.float_to_binary(decimals: 1) %>%
                      </span>
                    </td>
                    <td class="px-4 py-2 text-right font-bold text-blue-700">
                      <%= Enum.at(@mmm_result.contribution_pct, i) |> :erlang.float_to_binary(decimals: 1) %>%
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p class="text-xs text-gray-400 mt-3 text-center">
              Adstock = gasto acumulado com carry-over (decay=<%= @mmm_result.decay %>) &nbsp;|&nbsp; Hill α=<%= @mmm_result.alpha %> &nbsp;|&nbsp; K=R$ <%= format_brl(@mmm_result.half_saturation) %>
            </p>
          </div>
          <div :if={is_nil(@mmm_result) and not @mmm_loading} class="flex flex-col items-center justify-center py-16 text-center">
            <div class="text-5xl mb-4">📈</div>
            <h3 class="text-lg font-semibold text-gray-700">Selecione uma campanha e calcule o Adstock</h3>
            <p class="text-sm text-gray-500 mt-2 max-w-md">
              O Adstock modela que anúncios têm efeito que persiste além do dia do investimento.
              Ajuste o carry-over e a curva de saturação para simular diferentes cenários.
            </p>
          </div>
        </div>

        <%!-- ABA: OBSERVABILIDADE --%>
        <div :if={@active_tab == :observability} class="p-6">
          <div class="flex items-center justify-between mb-6">
            <div>
              <h2 class="text-lg font-bold text-gray-900">🔍 Observabilidade — Pipeline em Tempo Real</h2>
              <p class="text-sm text-gray-500 mt-0.5">
                Cada pergunta percorre 3 fases: LLM → Guardrail Rust → Query SQLite.
                Este painel mostra a latência de cada fase e o histórico de acessos.
              </p>
            </div>
          </div>

          <%!-- Gauges de saúde --%>
          <div class="grid grid-cols-2 gap-4 mb-6 sm:grid-cols-4">
            <.kpi_card
              title="Queries Totais"
              value={Integer.to_string(@tele_stats.total)}
              sub="nesta sessão"
              color="blue"
              icon="📨"
            />
            <.kpi_card
              title="Bloqueios Guardrail"
              value={Integer.to_string(@tele_stats.blocked_count)}
              sub="queries DML rejeitadas"
              color="orange"
              icon="🛡️"
            />
            <.kpi_card
              title="Guardrail Médio"
              value={"#{@tele_stats.avg_guardrail_us}µs"}
              sub="NIF Rust (validacao)"
              color="purple"
              icon="⚡"
            />
            <.kpi_card
              title="Query Média"
              value={"#{@tele_stats.avg_query_ms}ms"}
              sub="SQLite (execucao)"
              color="green"
              icon="🗃️"
            />
          </div>

          <%!-- Explicação visual do pipeline para CMO --%>
          <div class="bg-white rounded-xl border border-gray-200 p-5 mb-6 shadow-sm">
            <h3 class="text-sm font-semibold text-gray-700 mb-4">Como funciona o pipeline de segurança?</h3>
            <div class="flex items-center gap-2 flex-wrap">
              <div class="flex items-center gap-2 bg-blue-50 border border-blue-200 rounded-lg px-3 py-2">
                <span class="text-lg">💬</span>
                <div>
                  <p class="text-xs font-bold text-blue-800">1. LLM</p>
                  <p class="text-xs text-blue-600">Pergunta → SQL</p>
                  <p class="text-xs text-blue-400">(Ollama / Mock)</p>
                </div>
              </div>
              <span class="text-gray-400 text-lg">→</span>
              <div class="flex items-center gap-2 bg-orange-50 border border-orange-200 rounded-lg px-3 py-2">
                <span class="text-lg">🛡️</span>
                <div>
                  <p class="text-xs font-bold text-orange-800">2. Guardrail Rust</p>
                  <p class="text-xs text-orange-600">Valida READ-ONLY</p>
                  <p class="text-xs text-orange-400"><%= @tele_stats.avg_guardrail_us %>µs médio</p>
                </div>
              </div>
              <span class="text-gray-400 text-lg">→</span>
              <div class="flex items-center gap-2 bg-green-50 border border-green-200 rounded-lg px-3 py-2">
                <span class="text-lg">🗃️</span>
                <div>
                  <p class="text-xs font-bold text-green-800">3. SQLite</p>
                  <p class="text-xs text-green-600">Executa query</p>
                  <p class="text-xs text-green-400"><%= @tele_stats.avg_query_ms %>ms médio</p>
                </div>
              </div>
              <span class="text-gray-400 text-lg">→</span>
              <div class="flex items-center gap-2 bg-purple-50 border border-purple-200 rounded-lg px-3 py-2">
                <span class="text-lg">📊</span>
                <div>
                  <p class="text-xs font-bold text-purple-800">4. Z-Score</p>
                  <p class="text-xs text-purple-600">Detecta anomalias</p>
                  <p class="text-xs text-purple-400">NIF Rust</p>
                </div>
              </div>
            </div>
          </div>

          <%!-- Timeline de eventos --%>
          <div class="bg-white rounded-xl border border-gray-200 overflow-hidden shadow-sm">
            <div class="px-4 py-3 bg-gray-50 border-b border-gray-200 flex items-center justify-between">
              <h3 class="text-sm font-semibold text-gray-700">📜 Histórico de Queries (últimas 20)</h3>
              <span class="text-xs text-gray-400">Atualiza em tempo real via PubSub</span>
            </div>
            <div :if={@tele_events == []} class="px-4 py-10 text-center text-gray-400 text-sm">
              Nenhuma query registrada ainda. Vá para a aba Insights e faça uma pergunta.
            </div>
            <div :if={@tele_events != []}>
              <table class="w-full text-sm">
                <thead class="border-b border-gray-100">
                  <tr>
                    <th class="text-left px-4 py-2 text-xs font-semibold text-gray-400 uppercase">Hora</th>
                    <th class="text-left px-4 py-2 text-xs font-semibold text-gray-400 uppercase">Pergunta</th>
                    <th class="text-left px-4 py-2 text-xs font-semibold text-gray-400 uppercase">Status</th>
                    <th class="text-right px-4 py-2 text-xs font-semibold text-gray-400 uppercase">Guardrail</th>
                    <th class="text-right px-4 py-2 text-xs font-semibold text-gray-400 uppercase">Query</th>
                    <th class="text-left px-4 py-2 text-xs font-semibold text-gray-400 uppercase">SQL gerado</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-50">
                  <tr :for={ev <- @tele_events} class="hover:bg-gray-50 transition">
                    <td class="px-4 py-2.5 text-xs text-gray-500 whitespace-nowrap">
                      <%= ev.at |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8) %>
                    </td>
                    <td class="px-4 py-2.5 text-xs text-gray-700 max-w-[180px] truncate" title={ev.question}>
                      <%= ev.question %>
                    </td>
                    <td class="px-4 py-2.5">
                      <span class={tele_status_badge(ev.status)}>
                        <%= tele_status_label(ev.status) %>
                      </span>
                    </td>
                    <td class="px-4 py-2.5 text-right">
                      <span class={latency_bar_class(ev.guardrail_us, :us)}>
                        <%= ev.guardrail_us %>µs
                      </span>
                    </td>
                    <td class="px-4 py-2.5 text-right">
                      <span class={latency_bar_class(ev.query_ms, :ms)}>
                        <%= ev.query_ms %>ms
                      </span>
                    </td>
                    <td class="px-4 py-2.5">
                      <div class="flex items-center gap-1">
                        <code class="text-xs text-gray-500 font-mono max-w-[200px] truncate block" title={ev.sql}>
                          <%= if ev.sql == "", do: "—", else: ev.sql %>
                        </code>
                        <button :if={ev.sql != ""}
                          phx-click="copy_sql" phx-value-sql={ev.sql}
                          class="text-gray-300 hover:text-blue-500 transition flex-shrink-0"
                          title="Copiar SQL"
                        >
                          📋
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Nota técnica para a apresentação --%>
          <div class="mt-6 bg-gray-50 border border-gray-200 rounded-xl p-4">
            <p class="text-xs text-gray-500">
              ⚡ <strong>Por que o Guardrail Rust mede em microsegundos?</strong>
              O NIF <code>validate_read_only_sql</code> roda em Rust nativo dentro da BEAM —
              sem serialização, sem HTTP, sem overhead de processo. É tipicamente
              <strong>100× mais rápido</strong> que uma validação equivalente em Elixir puro
              e <strong>1.000× mais rápido</strong> que um microserviço externo.
              O banco SQLite opera em milissegundos porque faz I/O de disco — e ainda assim
              é mais rápido que uma query remota.
            </p>
          </div>
        </div>

        <%!-- ABA: SENTINEL --%>
        <div :if={@active_tab == :sentinel} class="p-6">
          <div class="flex items-center justify-between mb-4">
            <div>
              <h2 class="text-lg font-bold text-gray-900">🚨 Sentinel — Monitor de Anomalias</h2>
              <p class="text-sm text-gray-500 mt-0.5">
                Alertas gerados pelo NIF Rust <code class="bg-gray-100 px-1 rounded text-xs">calculate_zscore</code>.
                Um |Z| &gt; 3.0 indica anomalia com 99.7% de confiança.
              </p>
            </div>
            <div class="text-right">
              <p class="text-2xl font-bold text-gray-900"><%= @anomaly_count %></p>
              <p class="text-xs text-gray-400">alertas ativos</p>
            </div>
          </div>
          <div :if={@anomaly_alerts == []} class="flex flex-col items-center justify-center py-16 text-center">
            <div class="text-5xl mb-4">✅</div>
            <h3 class="text-lg font-semibold text-gray-700">Nenhuma anomalia detectada</h3>
            <p class="text-sm text-gray-500 mt-2 max-w-sm">
              O Sentinel monitora gastos via PubSub. Quando um Z-Score ultrapassar 3.0, o alerta aparece aqui.
            </p>
          </div>
          <div :if={@anomaly_alerts != []} class="space-y-3">
            <div :for={alert <- @anomaly_alerts}
              class={["rounded-xl border p-4 flex items-start justify-between",
                if(alert.severity == :critical, do: "bg-red-50 border-red-200", else: "bg-yellow-50 border-yellow-200")]}
            >
              <div class="flex items-start gap-3">
                <span class="text-2xl mt-0.5"><%= if alert.severity == :critical, do: "🔴", else: "🟡" %></span>
                <div>
                  <p class={["font-semibold text-sm", if(alert.severity == :critical, do: "text-red-800", else: "text-yellow-800")]}>
                    <%= if alert.severity == :critical, do: "Anomalia Crítica", else: "Anomalia Detectada" %>
                  </p>
                  <p class={["text-sm mt-0.5", if(alert.severity == :critical, do: "text-red-700", else: "text-yellow-700")]}>
                    Campanha: <strong><%= alert.campaign_id %></strong>
                  </p>
                  <div class="flex items-center gap-4 mt-2">
                    <div class="text-center">
                      <p class={["text-xl font-bold", if(alert.severity == :critical, do: "text-red-600", else: "text-yellow-600")]}><%= alert.z_score %></p>
                      <p class="text-xs text-gray-500">Z-Score</p>
                    </div>
                    <div class="text-center">
                      <p class="text-sm font-medium text-gray-700"><%= alert.at %> UTC</p>
                      <p class="text-xs text-gray-500">Detectado em</p>
                    </div>
                    <div class="text-center">
                      <p class={["text-sm font-bold", if(alert.severity == :critical, do: "text-red-600", else: "text-yellow-600")]}>
                        <%= if alert.severity == :critical, do: "+3σ CRÍTICO", else: "+3σ ATENÇÃO" %>
                      </p>
                      <p class="text-xs text-gray-500">Confiança: 99.7%</p>
                    </div>
                  </div>
                </div>
              </div>
              <button phx-click="dismiss_alert" phx-value-id={alert.id}
                class={["text-sm ml-2 mt-0.5", if(alert.severity == :critical, do: "text-red-400 hover:text-red-600", else: "text-yellow-400 hover:text-yellow-600")]}>✕</button>
            </div>
          </div>
          <div class="mt-8 bg-blue-50 border border-blue-200 rounded-xl p-5">
            <h3 class="text-sm font-bold text-blue-800 mb-2">📘 O que é o Z-Score?</h3>
            <p class="text-sm text-blue-700">
              O Z-Score mede quantos <strong>desvios padrão</strong> um gasto está afastado da média histórica.
              Acima de <strong>3.0</strong> é estatisticamente incomum — pode indicar bug, fraude ou oportunidade.
            </p>
            <div class="flex gap-6 mt-3">
              <div class="text-center"><p class="text-lg font-bold text-green-600">|Z| &lt; 2</p><p class="text-xs text-gray-500">Normal</p></div>
              <div class="text-center"><p class="text-lg font-bold text-yellow-600">2 ≤ |Z| &lt; 4</p><p class="text-xs text-gray-500">Atenção</p></div>
              <div class="text-center"><p class="text-lg font-bold text-red-600">|Z| ≥ 4</p><p class="text-xs text-gray-500">Crítico</p></div>
            </div>
          </div>
        </div>

      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Componentes
  # ---------------------------------------------------------------------------

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, required: true
  attr :color, :string, required: true
  attr :icon, :string, required: true

  defp kpi_card(assigns) do
    ~H"""
    <div class={["rounded-xl border p-4 bg-white shadow-sm", kpi_border_class(@color)]}>
      <div class="flex items-center justify-between mb-1">
        <span class="text-xs font-medium text-gray-500 uppercase tracking-wide"><%= @title %></span>
        <span class="text-lg"><%= @icon %></span>
      </div>
      <p class={["text-2xl font-bold", kpi_text_class(@color)]}><%= @value %></p>
      <p class="text-xs text-gray-400 mt-0.5"><%= @sub %></p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers — dados MMM
  # ---------------------------------------------------------------------------

  defp load_mmm_campaigns do
    from(m in "campaign_metrics",
      group_by: m.campaign_id,
      order_by: [desc: sum(m.spend)],
      select: m.campaign_id
    ) |> Repo.all()
  end

  defp get_first_campaign([]), do: nil
  defp get_first_campaign([first | _]), do: first

  defp load_campaign_spends(nil), do: []
  defp load_campaign_spends(campaign_id) do
    from(m in "campaign_metrics",
      where: m.campaign_id == ^campaign_id,
      order_by: m.date,
      select: m.spend
    ) |> Repo.all() |> Enum.map(&(&1 * 1.0))
  end

  defp load_campaign_dates(nil), do: []
  defp load_campaign_dates(campaign_id) do
    from(m in "campaign_metrics",
      where: m.campaign_id == ^campaign_id,
      order_by: m.date,
      select: m.date
    ) |> Repo.all()
  end

  defp maybe_push_chart_event(socket, nil, _dates), do: socket
  defp maybe_push_chart_event(socket, result, dates) do
    labels = Enum.map(dates, &format_date/1)
    push_event(socket, "adstock_data", %{
      labels: labels,
      spends: result.spends,
      adstock: Enum.map(result.adstock_values, &Float.round(&1, 2)),
      contribution_pct: Enum.map(result.contribution_pct, &Float.round(&1, 2))
    })
  end

  defp median([]), do: 1.0
  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)
    if rem(n, 2) == 0,
      do: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0,
      else: Enum.at(sorted, mid)
  end

  # ---------------------------------------------------------------------------
  # Helpers — formatação
  # ---------------------------------------------------------------------------

  defp format_date(nil), do: "—"
  defp format_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m")
  defp format_date(s) when is_binary(s), do: s
  defp format_date(other), do: inspect(other)

  defp format_brl(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 0)
  defp format_brl(v) when is_integer(v), do: Integer.to_string(v)
  defp format_brl(nil), do: "0"

  defp format_number(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.split("") |> Enum.chunk_every(3) |> Enum.join(".") |> String.reverse()
  end
  defp format_number(n) when is_float(n), do: format_number(round(n))
  defp format_number(nil), do: "0"

  defp load_campaigns(platform \\ "all") do
    query =
      from m in "campaign_metrics",
        group_by: [m.campaign_id, m.platform],
        order_by: [desc: sum(m.spend)],
        select: %{
          campaign_id: m.campaign_id,
          platform: m.platform,
          spend: sum(m.spend),
          clicks: sum(m.clicks),
          conversions: sum(m.conversions),
          impressions: sum(m.impressions)
        }
    query = if platform == "all", do: query, else: from(m in query, where: m.platform == ^platform)
    Repo.all(query)
    |> Enum.map(fn row ->
      cpc = if row.clicks > 0, do: row.spend / row.clicks, else: 0.0
      cpa = if row.conversions > 0, do: row.spend / row.conversions, else: 0.0
      cvr = if row.clicks > 0, do: row.conversions / row.clicks, else: 0.0
      Map.merge(row, %{cpc: cpc, cpa: cpa, cvr: cvr})
    end)
  end

  defp compute_kpis([]), do: %{total_spend: 0.0, total_clicks: 0, total_conversions: 0, avg_cpc: 0.0}
  defp compute_kpis(campaigns) do
    total_spend = Enum.sum(Enum.map(campaigns, & &1.spend))
    total_clicks = Enum.sum(Enum.map(campaigns, & &1.clicks))
    total_conversions = Enum.sum(Enum.map(campaigns, & &1.conversions))
    avg_cpc = if total_clicks > 0, do: total_spend / total_clicks, else: 0.0
    %{total_spend: total_spend, total_clicks: total_clicks, total_conversions: total_conversions, avg_cpc: avg_cpc}
  end

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
        "Nenhum resultado encontrado."
      else
        result.rows
        |> Enum.map(fn row ->
          Enum.zip(result.columns, row)
          |> Enum.map_join("  |  ", fn {col, val} -> "#{col}: #{format_value(val)}" end)
        end)
        |> Enum.join("\n")
      end
    anomaly_note = if result[:anomaly], do: "\n\n⚠️ Anomalia (Z: #{Float.round(result.z_score, 2)})", else: ""
    %{
      role: :assistant,
      content: content <> anomaly_note,
      status: :ok,
      icon: "📋",
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

  defp platform_label("all"), do: "Todos"
  defp platform_label(p), do: String.capitalize(p)

  defp parse_slider(v, default) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> default
    end
  end
  defp parse_slider(v, _) when is_float(v), do: v
  defp parse_slider(v, _) when is_integer(v), do: v * 1.0
  defp parse_slider(_, default), do: default

  defp saturation_badge(v) when v >= 0.7, do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-red-100 text-red-700"
  defp saturation_badge(v) when v >= 0.4, do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-yellow-100 text-yellow-700"
  defp saturation_badge(_), do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-green-100 text-green-700"

  defp tele_status_badge(:ok),      do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-green-100 text-green-700"
  defp tele_status_badge(:blocked), do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-orange-100 text-orange-700"
  defp tele_status_badge(:error),   do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-red-100 text-red-700"
  defp tele_status_badge(_),        do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-gray-100 text-gray-700"

  defp tele_status_label(:ok),      do: "✅ ok"
  defp tele_status_label(:blocked), do: "🛡️ bloqueado"
  defp tele_status_label(:error),   do: "⚠️ erro"
  defp tele_status_label(_),        do: "?"

  defp latency_bar_class(v, :us) when v < 500,  do: "text-xs font-mono font-bold text-green-600"
  defp latency_bar_class(v, :us) when v < 2000, do: "text-xs font-mono font-bold text-yellow-600"
  defp latency_bar_class(_, :us),               do: "text-xs font-mono font-bold text-red-600"
  defp latency_bar_class(v, :ms) when v < 10,   do: "text-xs font-mono font-bold text-green-600"
  defp latency_bar_class(v, :ms) when v < 50,   do: "text-xs font-mono font-bold text-yellow-600"
  defp latency_bar_class(_, :ms),               do: "text-xs font-mono font-bold text-red-600"

  defp tab_class(true),  do: "px-4 py-2 text-sm font-semibold text-blue-600 border-b-2 border-blue-600 -mb-px transition whitespace-nowrap"
  defp tab_class(false), do: "px-4 py-2 text-sm font-medium text-gray-500 hover:text-gray-700 border-b-2 border-transparent -mb-px transition whitespace-nowrap"

  defp kpi_border_class("blue"),   do: "border-blue-200"
  defp kpi_border_class("green"),  do: "border-green-200"
  defp kpi_border_class("purple"), do: "border-purple-200"
  defp kpi_border_class("orange"), do: "border-orange-200"
  defp kpi_border_class(_),        do: "border-gray-200"

  defp kpi_text_class("blue"),   do: "text-blue-700"
  defp kpi_text_class("green"),  do: "text-green-700"
  defp kpi_text_class("purple"), do: "text-purple-700"
  defp kpi_text_class("orange"), do: "text-orange-700"
  defp kpi_text_class(_),        do: "text-gray-700"

  defp platform_badge_class("google"),   do: "inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-700"
  defp platform_badge_class("meta"),     do: "inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-indigo-100 text-indigo-700"
  defp platform_badge_class("tiktok"),   do: "inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-pink-100 text-pink-700"
  defp platform_badge_class("linkedin"), do: "inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-sky-100 text-sky-700"
  defp platform_badge_class(_),          do: "inline-block px-2 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-700"

  defp cvr_badge_class(cvr) when cvr >= 0.05, do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-green-100 text-green-700"
  defp cvr_badge_class(cvr) when cvr >= 0.02, do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-yellow-100 text-yellow-700"
  defp cvr_badge_class(_), do: "inline-block px-2 py-0.5 rounded-full text-xs font-bold bg-red-100 text-red-700"

  defp message_wrapper_class(:user), do: "flex justify-end"
  defp message_wrapper_class(_), do: "flex justify-start"

  defp message_bubble_class(%{role: :user}),      do: "max-w-[75%] bg-blue-600 text-white rounded-2xl rounded-tr-sm px-4 py-2.5"
  defp message_bubble_class(%{status: :blocked}), do: "max-w-[85%] bg-red-50 border border-red-200 text-red-800 rounded-2xl rounded-tl-sm px-4 py-2.5"
  defp message_bubble_class(%{status: :error}),   do: "max-w-[85%] bg-yellow-50 border border-yellow-200 text-yellow-800 rounded-2xl rounded-tl-sm px-4 py-2.5"
  defp message_bubble_class(%{loading: true}),    do: "max-w-[85%] bg-gray-50 border border-gray-200 rounded-2xl rounded-tl-sm px-4 py-2.5"
  defp message_bubble_class(_),                   do: "max-w-[85%] bg-white border border-gray-200 text-gray-800 rounded-2xl rounded-tl-sm px-4 py-2.5 shadow-sm"
end
