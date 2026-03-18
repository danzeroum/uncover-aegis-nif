defmodule UncoverAegisWeb.Layouts do
  @moduledoc """
  Layouts HTML do Uncover Aegis.

  Estrategia CDN-first: Tailwind CSS, Chart.js e Phoenix LiveView JS sao
  carregados via CDN. Elimina a necessidade de pipeline de assets.

  Chart.js e usado com LiveView hooks para renderizar graficos MMM
  com dados calculados pelo NIF Rust (calculate_adstock).
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="pt-BR" class="h-full bg-gray-50">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Uncover Aegis | Trust OS</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.2/dist/chart.umd.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/phoenix@1.7.21/priv/static/phoenix.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.17/priv/static/phoenix_live_view.min.js"></script>
        <script>
          // ----------------------------------------------------------------
          // Hooks LiveView para graficos Chart.js
          // ----------------------------------------------------------------
          const AegisCharts = {};

          // Hook: grafico de barras agrupadas Spend vs Adstock
          AegisCharts.AdstockBar = {
            chart: null,
            mounted() {
              this.chart = new Chart(this.el, {
                type: "bar",
                data: { labels: [], datasets: [] },
                options: {
                  responsive: true,
                  maintainAspectRatio: false,
                  plugins: { legend: { position: "top" } },
                  scales: {
                    x: { grid: { display: false } },
                    y: { beginAtZero: true, ticks: {
                      callback: v => "R$ " + v.toLocaleString("pt-BR")
                    }}
                  }
                }
              });
              this.handleEvent("adstock_data", ({ labels, spends, adstock }) => {
                this.chart.data.labels = labels;
                this.chart.data.datasets = [
                  {
                    label: "Gasto Real (R$)",
                    data: spends,
                    backgroundColor: "rgba(59,130,246,0.7)",
                    borderColor: "rgba(59,130,246,1)",
                    borderWidth: 1,
                    borderRadius: 4
                  },
                  {
                    label: "Impacto Acumulado / Adstock (R$)",
                    data: adstock,
                    backgroundColor: "rgba(16,185,129,0.7)",
                    borderColor: "rgba(16,185,129,1)",
                    borderWidth: 1,
                    borderRadius: 4
                  }
                ];
                this.chart.update();
              });
            },
            destroyed() { if (this.chart) this.chart.destroy(); }
          };

          // Hook: donut de contribuição % por período
          AegisCharts.ContribDonut = {
            chart: null,
            mounted() {
              this.chart = new Chart(this.el, {
                type: "doughnut",
                data: { labels: [], datasets: [] },
                options: {
                  responsive: true,
                  maintainAspectRatio: false,
                  plugins: {
                    legend: { position: "right" },
                    tooltip: {
                      callbacks: {
                        label: ctx => ` ${ctx.parsed.toFixed(1)}%`
                      }
                    }
                  }
                }
              });
              this.handleEvent("adstock_data", ({ labels, contribution_pct }) => {
                const colors = [
                  "rgba(59,130,246,0.8)",
                  "rgba(16,185,129,0.8)",
                  "rgba(245,158,11,0.8)",
                  "rgba(139,92,246,0.8)",
                  "rgba(239,68,68,0.8)",
                  "rgba(20,184,166,0.8)",
                  "rgba(249,115,22,0.8)",
                  "rgba(236,72,153,0.8)"
                ];
                this.chart.data.labels = labels;
                this.chart.data.datasets = [{
                  data: contribution_pct,
                  backgroundColor: colors.slice(0, labels.length),
                  borderWidth: 2,
                  borderColor: "#fff"
                }];
                this.chart.update();
              });
            },
            destroyed() { if (this.chart) this.chart.destroy(); }
          };

          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: { _csrf_token: csrfToken },
              hooks: AegisCharts
            });
            liveSocket.connect();
          });
        </script>
      </head>
      <body class="h-full antialiased font-sans">
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <main class="mx-auto max-w-4xl px-4 py-8 h-screen flex flex-col">
      <%= @inner_content %>
    </main>
    """
  end
end
