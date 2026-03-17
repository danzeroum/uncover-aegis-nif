defmodule UncoverAegis.Sentinel.DynamicSupervisor do
  @moduledoc """
  Supervisor dinâmico que gerencia os processos `CampaignMonitor` sob demanda.

  ## Por que DynamicSupervisor?

  Um `Supervisor` estático exige que todos os filhos sejam conhecidos em
  tempo de compilação. O `DynamicSupervisor` permite iniciar e encerrar
  processos filhos em tempo de execução, ideal para modelar entidades
  dinâmicas como campanhas de marketing que surgem e somem continuamente.

  ## Estratégia de Restart: `:transient`

  Os filhos usam `:transient` (não `:permanent`). Isso significa:
  - Se o processo **crasha** (termina com erro) → o supervisor o **reinicia**.
  - Se o processo **para normalmente** (`:normal`, `:shutdown`) → **não reinicia**.

  Isso é correto para campanhas: uma campanha encerrada (stop_campaign) não
  deve ser reiniciada automaticamente.
  """

  use DynamicSupervisor

  alias UncoverAegis.Sentinel.CampaignMonitor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia um `CampaignMonitor` para a campanha, se ainda não existir.

  Operação idempotente: chamar duas vezes para a mesma campanha é seguro.
  O padrão `{:error, {:already_started, pid}}` é tratado como `:ok`.
  """
  @spec start_campaign(String.t()) :: :ok | {:error, term()}
  def start_campaign(campaign_id) do
    child_spec = %{
      id: {CampaignMonitor, campaign_id},
      start: {CampaignMonitor, :start_link, [campaign_id]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Para graciosamente o monitor de uma campanha.

  Usa `:global.whereis_name/1` para localizar o PID do processo antes
  de pedir ao DynamicSupervisor para encerrá-lo. Se já não existir,
  retorna `:ok` silenciosamente (idempotente).
  """
  @spec stop_campaign(String.t()) :: :ok | {:error, term()}
  def stop_campaign(campaign_id) do
    case :global.whereis_name({:campaign_monitor, campaign_id}) do
      :undefined ->
        :ok

      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
