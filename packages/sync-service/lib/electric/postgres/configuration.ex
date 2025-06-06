defmodule Electric.Postgres.Configuration do
  @moduledoc """
  Module for functions that configure Postgres in some way using
  a provided connection.
  """
  require Logger
  alias Electric.Replication.PublicationManager.RelationFilter
  alias Electric.Utils

  @type filters() :: %{Electric.relation() => RelationFilter.t()}

  @pg_15 150_000

  @doc """
  Ensure that all tables are configured for replication.

  Table is considered configured for replication when it's `REPLICA IDENTITY` is set to `FULL`
  and it's added to the specified publication.

  Important: this function should not be ran in a transaction, because it starts multiple
  internal transactions that are sometimes expected to fail.

  Raises if it fails to configure all the tables in the expected way.
  """
  @spec configure_tables_for_replication!(
          Postgrex.conn(),
          filters(),
          String.t(),
          float()
        ) ::
          {:ok, [:ok]}
  def configure_tables_for_replication!(pool, relation_filters, pg_version, publication_name) do
    Postgrex.transaction(
      pool,
      fn conn ->
        configure_tables_for_replication_internal!(
          conn,
          relation_filters,
          pg_version,
          publication_name
        )
      end
    )
  end

  @doc """
  Get Postgres server version
  """
  @spec get_pg_version(Postgrex.conn()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_pg_version(conn) do
    case Postgrex.query(
           conn,
           "SELECT current_setting('server_version_num') server_version_num",
           []
         ) do
      {:ok, result} when result.num_rows == 1 ->
        [[version_str]] = result.rows
        {:ok, String.to_integer(version_str)}

      {:error, err} ->
        {:error, err}
    end
  end

  defp configure_tables_for_replication_internal!(
         conn,
         relation_filters,
         pg_version,
         publication_name
       )
       when pg_version < @pg_15 do
    publication = Utils.quote_name(publication_name)

    relation_filters = filter_for_existing_relations(conn, relation_filters)

    prev_published_tables =
      get_publication_tables(conn, publication_name)
      |> Enum.map(&Utils.relation_to_sql/1)
      |> MapSet.new()

    new_published_tables =
      relation_filters
      |> Map.keys()
      |> Enum.map(&Utils.relation_to_sql/1)
      |> MapSet.new()

    alter_ops =
      Enum.concat(
        MapSet.difference(new_published_tables, prev_published_tables)
        |> Enum.map(&{&1, "ADD"}),
        MapSet.difference(prev_published_tables, new_published_tables)
        |> Enum.map(&{&1, "DROP"})
      )

    for {table, op} <- alter_ops do
      Postgrex.query!(conn, "SAVEPOINT before_publication", [])

      # PG 14 and below do not support filters on tables of publications
      case Postgrex.query(conn, "ALTER PUBLICATION #{publication} #{op} TABLE #{table}", []) do
        {:ok, _} ->
          Postgrex.query!(conn, "RELEASE SAVEPOINT before_publication", [])
          :ok

        # Duplicate object error is raised if we're trying to add a table to the publication when it's already there.
        {:error, %{postgres: %{code: :duplicate_object}}} ->
          Postgrex.query!(conn, "ROLLBACK TO SAVEPOINT before_publication", [])
          Postgrex.query!(conn, "RELEASE SAVEPOINT before_publication", [])
          :ok

        {:error, reason} ->
          raise reason
      end
    end

    set_replica_identity!(conn, relation_filters)
    [:ok]
  end

  defp configure_tables_for_replication_internal!(
         conn,
         relation_filters,
         _pg_version,
         publication_name
       ) do
    # Ensure that all tables are present in the publication
    relation_filters = filter_for_existing_relations(conn, relation_filters)

    # Update the entire publication with the new filters
    Postgrex.query!(
      conn,
      make_alter_publication_query(publication_name, relation_filters),
      []
    )

    # `ALTER TABLE` should be after the publication altering, because it takes out an exclusive lock over this table,
    # but the publication altering takes out a shared lock on all mentioned tables, so a concurrent transaction will
    # deadlock if the order is reversed.
    set_replica_identity!(conn, relation_filters)

    [:ok]
  end

  defp set_replica_identity!(conn, relation_filters) do
    query_for_relations_without_full_identity = """
    WITH input_relations AS (
      SELECT
        UNNEST($1::text[]) AS schemaname,
        UNNEST($2::text[]) AS tablename
    )
    SELECT ir.schemaname, ir.tablename
    FROM input_relations ir
    JOIN pg_class pc ON pc.relname = ir.tablename
    JOIN pg_namespace pn ON pn.oid = pc.relnamespace
    WHERE pn.nspname = ir.schemaname AND relreplident != 'f'
    """

    params =
      relation_filters
      |> Map.keys()
      |> Enum.unzip()
      |> Tuple.to_list()

    %Postgrex.Result{rows: rows} =
      Postgrex.query!(conn, query_for_relations_without_full_identity, params)

    tables = for [schema, table] <- rows, do: Utils.relation_to_sql({schema, table})

    if tables != [] do
      Logger.info("Altering identity of #{Enum.join(tables, ", ")} to FULL")

      queries = for table <- tables, do: "ALTER TABLE #{table} REPLICA IDENTITY FULL;"

      Postgrex.query!(
        conn,
        """
        DO $$
        BEGIN
        #{Enum.join(queries, "\n")}
        END $$;
        """,
        []
      )

      Logger.info("Altered identity of #{Enum.join(tables, ", ")} to FULL")
    end
  end

  @spec get_publication_tables(Postgrex.conn(), String.t()) :: list(Electric.relation())
  def get_publication_tables(conn, publication) do
    # `pg_publication_tables` is too clever for us -- if you add a partitioned
    # table to the publication `pg_publication_tables` lists all the partitions
    # as members, not the actual partitioned table. `pg_publication_rel`
    # doesn't do this, it returns a direct list of the tables that were added
    # using `ALTER PUBLICATION` and doesn't expand a partitioned table into its
    # partitions.
    Postgrex.query!(
      conn,
      """
      SELECT pn.nspname, pc.relname
        FROM pg_publication_rel ppr
        JOIN pg_publication pp
          ON ppr.prpubid = pp.oid
        JOIN pg_class pc
          ON pc.oid = ppr.prrelid
        JOIN pg_namespace pn
          ON pc.relnamespace = pn.oid
        WHERE pp.pubname = $1
        ORDER BY pn.nspname, pc.relname;
      """,
      [publication]
    )
    |> Map.fetch!(:rows)
    |> Enum.map(&(Enum.take(&1, 2) |> List.to_tuple()))
  end

  # Makes an SQL query that alters the given publication whith the given tables and filters.
  @spec make_alter_publication_query(String.t(), filters()) :: String.t()
  defp make_alter_publication_query(publication_name, filters) do
    case Map.values(filters) do
      [] ->
        """
        DO $$
        DECLARE
            tables TEXT;
        BEGIN
            SELECT string_agg(format('%I.%I', pn.nspname, pc.relname), ', ') INTO tables
              FROM pg_publication_rel ppr
              JOIN pg_publication pp
                ON ppr.prpubid = pp.oid
              JOIN pg_class pc
                ON pc.oid = ppr.prrelid
              JOIN pg_namespace pn
                ON pc.relnamespace = pn.oid
              WHERE pp.pubname = '#{publication_name}';

            IF tables IS NOT NULL THEN
                EXECUTE format('ALTER PUBLICATION #{Utils.quote_name(publication_name)} DROP TABLE %s', tables);
            END IF;
        END $$;
        """

      filters ->
        base_sql = "ALTER PUBLICATION #{Utils.quote_name(publication_name)} SET TABLE "

        tables =
          filters
          |> Enum.map(&make_table_clause/1)
          |> Enum.join(", ")

        base_sql <> tables
    end
  end

  @spec filter_for_existing_relations(Postgrex.conn(), filters()) :: filters()
  defp filter_for_existing_relations(conn, filters) do
    query = """
    WITH input_relations AS (
        SELECT
          UNNEST($1::text[]) AS schemaname,
          UNNEST($2::text[]) AS tablename
    )
    SELECT ir.schemaname, ir.tablename
    FROM input_relations ir
    JOIN pg_class pc ON pc.relname = ir.tablename
    JOIN pg_namespace pn ON pn.oid = pc.relnamespace
    WHERE pn.nspname = ir.schemaname AND pc.relkind IN ('r', 'p');
    """

    relations = Map.keys(filters)

    Postgrex.query!(conn, query, [
      Enum.map(relations, &elem(&1, 0)),
      Enum.map(relations, &elem(&1, 1))
    ])
    |> Map.fetch!(:rows)
    |> Enum.map(&List.to_tuple/1)
    |> Enum.reduce(%{}, fn rel, new_filters ->
      case Map.get(filters, rel) do
        nil -> new_filters
        filter -> Map.put(new_filters, rel, filter)
      end
    end)
  end

  @spec make_table_clause(RelationFilter.t()) :: String.t()
  defp make_table_clause(%RelationFilter{
         relation: relation,
         where_clauses: where_clauses
         #  selected_columns: cols
       }) do
    table = Utils.relation_to_sql(relation)

    # NOTE: cannot filter on columns with REPLICA IDENTITY FULL
    # cols = if cols == nil, do: "", else: " (#{Enum.join(cols, ", ")})"
    cols = ""

    where =
      if where_clauses == nil,
        do: "",
        else:
          " WHERE " <>
            "(#{where_clauses |> Enum.map(& &1.query) |> Enum.join(" OR ")})"

    table <> cols <> where
  end
end
