import { Pool } from "pg";
import { assertDataPlaneCompatibility } from "@/lib/tenancy/data-plane-schema";

type Column = { name: string; ordinal: number };
type ForeignKey = {
  column: string;
  referencedSchema: string;
  referencedTable: string;
  referencedColumn: string;
};
type Table = {
  name: string;
  columns: Column[];
  primaryKey: string[];
  foreignKeys: ForeignKey[];
};

const CONTROL_ONLY = new Set([
  "organization_data_planes",
  "platform_admins",
  "platform_branding",
  "platform_google_oauth",
  "platform_support_sessions",
  "user_organizations",
  "user_recovery_codes",
]);

const qid = (value: string) => `"${value.replaceAll('"', '""')}"`;
const tableRef = (name: string) => `public.${qid(name)}`;

function arg(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

function requireOption(name: string): string {
  const value = arg(name)?.trim();
  if (!value) throw new Error(`${name} é obrigatório`);
  return value;
}

async function loadTables(pool: Pool): Promise<Map<string, Table>> {
  const columns = await pool.query<{ table_name: string; column_name: string; ordinal_position: number }>(
    `select table_name, column_name, ordinal_position
       from information_schema.columns
      where table_schema = 'public'
      order by table_name, ordinal_position`,
  );
  const tables = new Map<string, Table>();
  for (const row of columns.rows) {
    const table = tables.get(row.table_name) ?? {
      name: row.table_name,
      columns: [],
      primaryKey: [],
      foreignKeys: [],
    };
    table.columns.push({ name: row.column_name, ordinal: row.ordinal_position });
    tables.set(row.table_name, table);
  }

  const primaryKeys = await pool.query<{ table_name: string; column_name: string; ordinal_position: number }>(
    `select tc.table_name, kcu.column_name, kcu.ordinal_position
       from information_schema.table_constraints tc
       join information_schema.key_column_usage kcu
         on kcu.constraint_name = tc.constraint_name
        and kcu.table_schema = tc.table_schema
        and kcu.table_name = tc.table_name
      where tc.table_schema = 'public' and tc.constraint_type = 'PRIMARY KEY'
      order by tc.table_name, kcu.ordinal_position`,
  );
  for (const row of primaryKeys.rows) tables.get(row.table_name)?.primaryKey.push(row.column_name);

  const foreignKeys = await pool.query<{
    table_name: string;
    column_name: string;
    foreign_table_schema: string;
    foreign_table_name: string;
    foreign_column_name: string;
  }>(
    `select kcu.table_name, kcu.column_name, ccu.table_schema as foreign_table_schema,
            ccu.table_name as foreign_table_name,
            ccu.column_name as foreign_column_name
       from information_schema.table_constraints tc
       join information_schema.key_column_usage kcu
         on kcu.constraint_name = tc.constraint_name
        and kcu.table_schema = tc.table_schema
        and kcu.table_name = tc.table_name
       join information_schema.constraint_column_usage ccu
         on ccu.constraint_name = tc.constraint_name
      where tc.table_schema = 'public' and tc.constraint_type = 'FOREIGN KEY'`,
  );
  for (const row of foreignKeys.rows) {
    tables.get(row.table_name)?.foreignKeys.push({
      column: row.column_name,
      referencedSchema: row.foreign_table_schema,
      referencedTable: row.foreign_table_name,
      referencedColumn: row.foreign_column_name,
    });
  }
  return tables;
}

function scopedTables(source: Map<string, Table>, target: Map<string, Table>): Map<string, Table> {
  return new Map(
    [...source.entries()].filter(([name, table]) =>
      !CONTROL_ONLY.has(name) &&
      target.has(name) &&
      (table.columns.some((column) => column.name === "organization_id") || name === "organizations"),
    ),
  );
}

function includeDependentTables(
  all: Map<string, Table>,
  target: Map<string, Table>,
  selected: Map<string, Table>,
): void {
  let changed = true;
  while (changed) {
    changed = false;
    for (const [name, table] of all) {
      if (CONTROL_ONLY.has(name) || selected.has(name) || !target.has(name)) continue;
      const dependency = table.foreignKeys.some((foreignKey) => {
        if (foreignKey.referencedSchema !== "public") return false;
        const parent = selected.get(foreignKey.referencedTable);
        return parent?.columns.some((column) => column.name === "organization_id");
      });
      if (dependency) {
        selected.set(name, table);
        changed = true;
      }
    }
  }
}

function migrationOrder(tables: Map<string, Table>): string[] {
  const result: string[] = [];
  const visiting = new Set<string>();
  const visited = new Set<string>();
  const visit = (name: string) => {
    if (visited.has(name)) return;
    if (visiting.has(name)) return; // Cycles are handled by deferred constraints/ON CONFLICT.
    visiting.add(name);
    for (const foreignKey of tables.get(name)?.foreignKeys ?? []) {
      if (tables.has(foreignKey.referencedTable)) visit(foreignKey.referencedTable);
    }
    visiting.delete(name);
    visited.add(name);
    result.push(name);
  };
  for (const name of tables.keys()) visit(name);
  return result;
}

function predicateFor(table: Table, selected: Map<string, Table>): { sql: string; params: string[] } | null {
  if (table.name === "organizations") return { sql: `${qid("id")} = $1`, params: ["organization_id"] };
  if (table.columns.some((column) => column.name === "organization_id")) {
    return { sql: `${qid("organization_id")} = $1`, params: ["organization_id"] };
  }
  const predicates = table.foreignKeys.flatMap((foreignKey) => {
    if (foreignKey.referencedSchema !== "public") return [];
    const parent = selected.get(foreignKey.referencedTable);
    if (!parent || !parent.columns.some((column) => column.name === "organization_id")) return [];
    return [`exists (select 1 from ${tableRef(parent.name)} p where p.${qid(foreignKey.referencedColumn)} = t.${qid(foreignKey.column)} and p.${qid("organization_id")} = $1)`];
  });
  return predicates.length ? { sql: predicates.join(" or "), params: ["organization_id"] } : null;
}

async function countRows(pool: Pool, table: Table, predicate: string, organizationId: string): Promise<number> {
  const result = await pool.query<{ count: string }>(
    `select count(*)::text as count from ${tableRef(table.name)} t where ${predicate}`,
    [organizationId],
  );
  return Number(result.rows[0]?.count ?? 0);
}

async function copyTable(
  source: Pool,
  target: Pool,
  table: Table,
  predicate: string,
  organizationId: string,
): Promise<number> {
  const sourceRows = await source.query(`select * from ${tableRef(table.name)} t where ${predicate}`, [organizationId]);
  if (!sourceRows.rows.length) return 0;
  const targetColumns = new Set(
    (await target.query<{ column_name: string }>(
      `select column_name from information_schema.columns where table_schema = 'public' and table_name = $1`,
      [table.name],
    )).rows.map((row) => row.column_name),
  );
  const columns = table.columns.map((column) => column.name).filter((name) => targetColumns.has(name));
  if (!columns.length) return 0;
  const values = columns.map((_, index) => `$${index + 1}`).join(", ");
  const statement = `insert into ${tableRef(table.name)} (${columns.map(qid).join(", ")}) values (${values}) on conflict do nothing`;
  let copied = 0;
  for (const row of sourceRows.rows as Record<string, unknown>[]) {
    await target.query(statement, columns.map((column) => row[column]));
    copied += 1;
  }
  return copied;
}

async function assertAuthReferences(
  source: Pool,
  target: Pool,
  tables: Map<string, Table>,
  plan: Array<{ table: string; predicate: string }>,
  organizationId: string,
): Promise<void> {
  const missing: Array<{ table: string; column: string; count: number }> = [];
  for (const item of plan) {
    const table = tables.get(item.table)!;
    for (const foreignKey of table.foreignKeys) {
      if (foreignKey.referencedSchema !== "auth" || foreignKey.referencedTable !== "users") continue;
      const ids = await source.query<{ id: string }>(
        `select distinct t.${qid(foreignKey.column)}::text as id
           from ${tableRef(table.name)} t
          where (${item.predicate}) and t.${qid(foreignKey.column)} is not null`,
        [organizationId],
      );
      if (!ids.rows.length) continue;
      let found = 0;
      try {
        const result = await target.query<{ count: string }>(
          `select count(*)::text as count from auth.users where id::text = any($1::text[])`,
          [ids.rows.map((row) => row.id)],
        );
        found = Number(result.rows[0]?.count ?? 0);
      } catch (error) {
        throw new Error(`data_plane_auth_users_unavailable:${error instanceof Error ? error.message : String(error)}`);
      }
      if (found !== ids.rows.length) {
        missing.push({ table: table.name, column: foreignKey.column, count: ids.rows.length - found });
      }
    }
  }
  if (missing.length) throw new Error(`data_plane_auth_references_missing:${JSON.stringify(missing)}`);
}

async function main() {
  const sourceUrl = process.env.SOURCE_DATABASE_URL;
  const targetUrl = process.env.DATA_PLANE_DATABASE_URL;
  const organizationId = requireOption("--organization-id");
  if (!sourceUrl || !targetUrl) throw new Error("SOURCE_DATABASE_URL e DATA_PLANE_DATABASE_URL são obrigatórios e nunca serão exibidos");
  if (!/^[0-9a-f-]{36}$/i.test(organizationId)) throw new Error("--organization-id precisa ser UUID");
  if (sourceUrl === targetUrl) throw new Error("origem e destino não podem ser iguais");

  const source = new Pool({ connectionString: sourceUrl, max: 2, application_name: "deskcomm:tenant-migration-source" });
  const target = new Pool({ connectionString: targetUrl, max: 2, application_name: "deskcomm:tenant-migration-target" });
  try {
    await assertDataPlaneCompatibility(target);
    const [sourceTables, targetTables] = await Promise.all([loadTables(source), loadTables(target)]);
    const selected = scopedTables(sourceTables, targetTables);
    includeDependentTables(sourceTables, targetTables, selected);
    const order = migrationOrder(selected);
    const plan: Array<{ table: string; sourceRows: number; targetRows: number; copied?: number; predicate: string }> = [];
    for (const name of order) {
      const table = selected.get(name)!;
      const predicate = predicateFor(table, selected);
      if (!predicate) continue;
      const [sourceRows, targetRows] = await Promise.all([
        countRows(source, table, predicate.sql, organizationId),
        countRows(target, table, predicate.sql, organizationId),
      ]);
      plan.push({ table: name, sourceRows, targetRows, predicate: predicate.sql });
    }

    await assertAuthReferences(
      source,
      target,
      selected,
      plan.map(({ table, predicate }) => ({ table, predicate })),
      organizationId,
    );

    const apply = hasFlag("--apply");
    if (apply && !hasFlag("--confirm-org")) throw new Error("A escrita exige --apply --confirm-org <mesmo UUID>");
    if (apply && arg("--confirm-org") !== organizationId) throw new Error("--confirm-org precisa repetir --organization-id");

    if (!apply) {
      process.stdout.write(`${JSON.stringify({ mode: "dry-run", organizationId, tables: plan }, null, 2)}\n`);
      return;
    }

    await target.query("begin");
    try {
      for (const item of plan) {
        if (item.sourceRows === 0) continue;
        const table = selected.get(item.table)!;
        const predicate = predicateFor(table, selected)!;
        item.copied = await copyTable(source, target, table, predicate.sql, organizationId);
      }
      await target.query("commit");
    } catch (error) {
      await target.query("rollback");
      throw error;
    }

    const after = await Promise.all(plan.map(async (item) => ({
      table: item.table,
      expected: item.sourceRows,
      actual: await countRows(target, selected.get(item.table)!, item.predicate, organizationId),
    })));
    const mismatches = after.filter((item) => item.actual < item.expected);
    if (mismatches.length) throw new Error(`reconciliação incompleta: ${JSON.stringify(mismatches)}`);
    process.stdout.write(`${JSON.stringify({ mode: "apply", organizationId, tables: plan, reconciled: true }, null, 2)}\n`);
  } finally {
    await Promise.all([source.end(), target.end()]);
  }
}

void main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

