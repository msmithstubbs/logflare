defmodule Logflare.Repo.Migrations.RecreatePublicationForTables do
  use Ecto.Migration
  use Ecto.Migration

  @publications Application.compile_env(:logflare, Logflare.ContextCache.CacheBuster)[:publications]
  @publication_tables [
    "billing_accounts",
    "plans",
    "rules",
    "source_schemas",
    "sources",
    "users",
    "backends",
    "team_users"
  ]

  def up do
    for p <- @publications, do: execute("DROP PUBLICATION #{p};")
    for p <- @publications do
      tables = Enum.join(@publication_tables, ", ")
      execute("CREATE PUBLICATION #{p} FOR TABLE #{tables};")
    end
  end

  def down do
    :noop
  end
end
