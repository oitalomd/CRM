export const DATA_PLANE_SCHEMA_VERSION = 381;
export const DATA_PLANE_SCHEMA_NAME = "deskcomm_data_plane_schema";

type QueryResult = { rows: Array<Record<string, unknown>>; rowCount: number | null };
export type DataPlaneSchemaClient = {
  query(sql: string, values?: unknown[]): Promise<QueryResult>;
  release(): void;
};
type TransactionPool = { connect(): Promise<DataPlaneSchemaClient> };

export type DataPlaneSchemaResult = {
  action: "initialized" | "updated" | "unchanged";
  version: number;
  hash: string;
};

export async function assertDataPlaneCompatibility(pool: TransactionPool): Promise<void> {
  const client = await pool.connect();
  try {
    const result = await client.query(`
      select
        to_regnamespace('auth')::text as auth_schema,
        to_regnamespace('storage')::text as storage_schema,
        to_regnamespace('extensions')::text as extensions_schema,
        to_regtype('public.vector')::text as vector_type,
        to_regprocedure('extensions.uuid_generate_v4()')::text as uuid_generator,
        to_regprocedure('extensions.gen_random_bytes(integer)')::text as random_generator
    `);
    const row = result.rows[0] ?? {};
    const missing = [
      ["auth", row.auth_schema],
      ["storage", row.storage_schema],
      ["extensions", row.extensions_schema],
      ["public.vector", row.vector_type],
      ["extensions.uuid_generate_v4()", row.uuid_generator],
      ["extensions.gen_random_bytes(integer)", row.random_generator],
    ].filter(([, value]) => !value).map(([name]) => name);
    if (missing.length > 0) {
      throw new Error(`data_plane_database_incompatible:${missing.join(",")}`);
    }
  } finally {
    client.release();
  }
}

export async function ensureDataPlaneSchema(
  pool: TransactionPool,
  input: { sql: string; version?: number; hash: string },
): Promise<DataPlaneSchemaResult> {
  const version = input.version ?? DATA_PLANE_SCHEMA_VERSION;
  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query(`
      create table if not exists public.${DATA_PLANE_SCHEMA_NAME} (
        singleton boolean primary key default true check (singleton),
        schema_version integer not null check (schema_version >= 0),
        schema_hash text not null,
        applied_at timestamptz not null default now()
      )
    `);
    await client.query("select pg_advisory_xact_lock(hashtextextended($1, 0))", [
      `deskcomm:data-plane-schema:${version}`,
    ]);

    const current = (await client.query(
      `select schema_version, schema_hash from public.${DATA_PLANE_SCHEMA_NAME} where singleton = true`,
    )) as QueryResult;
    const row = current.rows[0] as
      | { schema_version: number; schema_hash: string }
      | undefined;

    if (row && row.schema_version > version) {
      throw new Error(
        `data_plane_schema_downgrade:${row.schema_version}->${version}`,
      );
    }
    if (row && row.schema_version === version && row.schema_hash !== input.hash) {
      throw new Error("data_plane_schema_hash_mismatch:version_requires_new_migration");
    }

    if (row && row.schema_version === version) {
      await client.query("commit");
      return { action: "unchanged", version, hash: input.hash };
    }

    await client.query(input.sql);
    await client.query(
      `insert into public.${DATA_PLANE_SCHEMA_NAME} (singleton, schema_version, schema_hash)
       values (true, $1, $2)
       on conflict (singleton) do update set
         schema_version = excluded.schema_version,
         schema_hash = excluded.schema_hash,
         applied_at = now()`,
      [version, input.hash],
    );
    await client.query("commit");
    return { action: row ? "updated" : "initialized", version, hash: input.hash };
  } catch (error) {
    await client.query("rollback").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

