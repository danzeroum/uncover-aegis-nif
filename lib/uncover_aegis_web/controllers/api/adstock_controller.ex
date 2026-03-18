defmodule UncoverAegisWeb.Api.AdstockController do
  use UncoverAegisWeb, :controller

  @moduledoc """
  Endpoint de Marketing Mix Modeling — Adstock com Saturação Hill.

  Expõe o NIF Rust `calculate_adstock` via API REST, permitindo que
  clientes calculem o impacto acumulado de campanhas ao longo do tempo
  considerando carry-over e saturação de mídia.

  ## POST /api/v1/mmm/adstock

  ### Body (JSON)
  ```json
  {
    "spends": [1200.0, 1350.0, 1100.0, 1280.0],
    "decay": 0.7,
    "alpha": 2.0,
    "half_saturation": 1500.0
  }
  ```

  ### Parâmetros
  - `spends` (obrigatório): lista de gastos por período em R$
  - `decay` (opcional, default: 0.7): carry-over entre 0.0 e 1.0
  - `alpha` (opcional, default: 2.0): expoente Hill (curva de saturação)
  - `half_saturation` (opcional, default: mediana dos spends): ponto de 50% de saturação

  ### Resposta de Sucesso (200)
  ```json
  {
    "adstock_values": [1200.0, 2190.0, 2833.0, 3063.1],
    "saturated_values": [0.39, 0.68, 0.78, 0.81],
    "contribution_pct": [14.6, 25.4, 29.2, 30.2],
    "meta": {
      "decay": 0.7,
      "alpha": 2.0,
      "half_saturation": 1500.0,
      "total_spend": 4930.0,
      "guardrail_rust_us": 312
    }
  }
  ```
  """

  alias UncoverAegis.Native

  @default_decay 0.7
  @default_alpha 2.0

  def calculate(conn, params) do
    start_time = System.monotonic_time(:microsecond)

    with {:ok, spends} <- parse_spends(params),
         {:ok, decay} <- parse_float(params, "decay", @default_decay),
         {:ok, alpha} <- parse_float(params, "alpha", @default_alpha),
         {:ok, half_sat} <- parse_half_saturation(params, spends),
         {:ok, result} <- Native.calculate_adstock(spends, decay, alpha, half_sat) do

      elapsed_us = System.monotonic_time(:microsecond) - start_time

      json(conn, %{
        adstock_values: round_list(result.adstock_values, 2),
        saturated_values: round_list(result.saturated_values, 4),
        contribution_pct: round_list(result.contribution_pct, 2),
        meta: %{
          decay: decay,
          alpha: alpha,
          half_saturation: half_sat,
          total_spend: Enum.sum(spends),
          guardrail_rust_us: elapsed_us
        }
      })
    else
      {:insufficient_data, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Lista de spends não pode ser vazia"})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Parâmetros inválidos. Verifique decay (0.0–1.0), alpha (> 0) e half_saturation (> 0)"})
    end
  end

  # ---------------------------------------------------------------------------
  # Parsers
  # ---------------------------------------------------------------------------

  defp parse_spends(%{"spends" => spends}) when is_list(spends) do
    parsed =
      Enum.reduce_while(spends, [], fn v, acc ->
        case to_float(v) do
          {:ok, f} -> {:cont, [f | acc]}
          :error -> {:halt, :error}
        end
      end)

    case parsed do
      :error -> {:error, "'spends' deve ser uma lista de números"}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_spends(_), do: {:error, "Campo 'spends' é obrigatório e deve ser uma lista"}

  defp parse_float(params, key, default) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      v -> case to_float(v) do
        {:ok, f} -> {:ok, f}
        :error -> {:error, "'#{key}' deve ser um número"}
      end
    end
  end

  # Se half_saturation não for fornecida, usa a mediana dos spends como padrão.
  # A mediana representa um ponto de gasto "normal" — razoável como ponto de 50% de saturação.
  defp parse_half_saturation(%{"half_saturation" => v}, _spends) do
    case to_float(v) do
      {:ok, f} -> {:ok, f}
      :error -> {:error, "'half_saturation' deve ser um número positivo"}
    end
  end

  defp parse_half_saturation(_params, spends) do
    median = median(spends)
    {:ok, median}
  end

  defp median([]), do: 1.0
  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)
    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2.0
    else
      Enum.at(sorted, mid)
    end
  end

  defp to_float(v) when is_float(v), do: {:ok, v}
  defp to_float(v) when is_integer(v), do: {:ok, v * 1.0}
  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> :error
    end
  end
  defp to_float(_), do: :error

  defp round_list(list, precision) do
    Enum.map(list, &Float.round(&1, precision))
  end
end
