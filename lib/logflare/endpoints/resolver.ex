defmodule Logflare.Endpoints.Resolver do
  @moduledoc """
  Finds or spawns Endpoint.Cache processes across the cluster. Unique process for query plus query params.
  """
  alias Logflare.Endpoints.ResultsCache

  require Logger

  @doc """
  Lists all caches for an endpoint across all paritions
  """
  def list_caches(%Logflare.Endpoints.Query{id: id}) do
    endpoints_partition = ResultsCache.endpoints_part(id)

    :syn.members(endpoints_partition, id)
    |> Enum.map(fn {pid, _} -> pid end)
  end

  @doc """
  Starts up or performs a lookup for an Endpoint.Cache process.
  Returns the resolved pid.
  """
  def resolve(%Logflare.Endpoints.Query{id: id} = query, params) do
    ResultsCache.name(query.id, params)
    |> GenServer.whereis()
    |> case do
      pid when is_pid(pid) ->
        pid

      nil ->
        spec = {ResultsCache, {query, params}}
        Logger.debug("Starting up Endpoint.Cache for Endpoint.Query id=#{id}", endpoint_id: id)

        via =
          {:via, PartitionSupervisor,
           {Logflare.Endpoints.ResultsCache.PartitionSupervisor, {id, params}}}

        case DynamicSupervisor.start_child(via, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end
