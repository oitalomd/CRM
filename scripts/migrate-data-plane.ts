import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { Pool } from "pg";

import {
  assertDataPlaneCompatibility,
  DATA_PLANE_SCHEMA_VERSION,
  ensureDataPlaneSchema,
} from "@/lib/tenancy/data-plane-schema";

async function main() {
  const url = process.env.DATA_PLANE_DATABASE_URL;
  if (!url) {
    throw new Error("DATA_PLANE_DATABASE_URL é obrigatório e não será exibido nos logs");
  }

  const baselinePath = resolve(process.cwd(), "supabase/baseline.sql");
  const sql = await readFile(baselinePath, "utf8");
  const hash = createHash("sha256").update(sql, "utf8").digest("hex");
  const pool = new Pool({
    connectionString: url,
    max: 1,
    connectionTimeoutMillis: 10_000,
    application_name: "deskcomm:data-plane-migrator",
  });

  try {
    await assertDataPlaneCompatibility(pool);
    const result = await ensureDataPlaneSchema(pool, {
      sql,
      version: DATA_PLANE_SCHEMA_VERSION,
      hash,
    });
    process.stdout.write(`${JSON.stringify({ ...result, baseline: baselinePath })}\n`);
  } finally {
    await pool.end();
  }
}

void main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 1;
});

