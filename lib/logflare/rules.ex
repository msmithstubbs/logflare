defmodule Logflare.Rules do
  @moduledoc false
  import Ecto.Query
  require Logger

  alias Logflare.Lql
  alias Logflare.Repo
  alias Logflare.Rules.Rule
  alias Logflare.Source
  alias Logflare.Sources
  alias Logflare.SourceSchemas
  alias Logflare.Backends.Backend
  alias Logflare.Backends.SourceSup
  alias Logflare.Cluster

  @doc """
  Lists rules for a given Source or Backend
  """
  @spec list_rules(Source.t() | Backend.t()) :: [Backend.t()]
  def list_rules(%Source{id: source_id}) do
    from(r in Rule, where: r.source_id == ^source_id)
    |> Repo.all()
  end

  def list_rules(%Backend{id: backend_id}) do
    from(r in Rule, where: r.backend_id == ^backend_id)
    |> Repo.all()
  end

  @doc """
  Creates a rule based on a given attr map.
  If it is a drain rule with an associated backend, it will attempt to start the backend child on SourceSup if it is running.
  """
  @spec create_rule(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs \\ %{}) do
    %Rule{}
    |> Rule.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, %Rule{backend_id: backend_id} = rule} = result when backend_id != nil ->
        # expected to fail on nodes where SourceSup is not started
        Cluster.Utils.rpc_multicall(SourceSup, :start_rule_child, [rule])

        result

      other ->
        other
    end
  end

  @doc """
  Updates a given rule.
  """
  @spec update_rule(Rule.t(), map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def update_rule(%Rule{} = rule, attrs) do
    rule
    |> Rule.changeset(attrs)
    |> Repo.update()
  end

  @doc "Retrieves a given Rule by id. Returns nil if not present."
  @spec get_rule(non_neg_integer()) :: Rule.t() | nil
  def get_rule(id), do: Repo.get(Rule, id)

  def fetch_rule_by(kw) do
    {user_id, kw} = Keyword.pop(kw, :user_id)

    from(r in Rule, join: s in Source, on: s.user_id == ^user_id)
    |> where([r], ^kw)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      rule -> {:ok, rule}
    end
  end

  @spec create_rule(map(), Source.t()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t() | binary}
  def create_rule(params, %Source{} = source) when is_map(params) do
    bq_schema =
      SourceSchemas.get_source_schema_by(source_id: source.id) |> Map.get(:bigquery_schema)

    lql_string = params["lql_string"]

    with {:ok, lql_filters} <- Lql.Parser.parse(lql_string, bq_schema),
         params = Map.put(params, "lql_filters", lql_filters),
         {:ok, rule} <- Rule.changeset(%Rule{source_id: source.id}, params) |> Repo.insert() do
      {:ok, rule}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      errtup -> errtup
    end
  end

  @doc """
  Deletes a given rule.
  Atempts to stop the rules associated backend child if SourceSup is started.
  """
  @spec delete_rule(Rule.t()) :: {:ok, Rule.t()}
  def delete_rule(rule) do
    res = Repo.delete(rule)
    Cluster.Utils.rpc_multicall(SourceSup, :stop_rule_child, [rule])

    res
  end

  def upgrade_all_source_rules_to_next_lql_version() do
    Logger.info("Started upgrade of all source rules to next lql version...")

    rules =
      Rule
      |> where([r], not is_nil(r.lql_filters) and not is_nil(r.lql_string))
      |> Repo.all()

    for rule <- rules do
      source =
        rule.source_id
        |> Sources.get()
        |> Sources.put_bq_table_schema()

      case Lql.decode(rule.lql_string, source.bq_table_schema) do
        {:ok, lql_filters} ->
          if lql_filters != rule.lql_filters do
            rule
            |> Rule.changeset(%{lql_filters: lql_filters})
            |> Repo.update()
            |> case do
              {:ok, r} ->
                Logger.info(
                  "Rule #{r.id} for source #{r.source_id} was successfully upgraded to new LQL filters format."
                )

              {:error, changeset} ->
                Logger.error(
                  "Rule #{rule.id} for source #{rule.source_id} failed to upgrade to new LQL filters format, Repo update erro: #{inspect(changeset.errors)}"
                )
            end
          end

        {:error, error} ->
          Logger.error(
            "Rule #{rule.id} for source #{rule.source_id} failed to upgrade to new LQL filters format, LQL decoding error: #{inspect(error)}"
          )
      end
    end
  end
end
