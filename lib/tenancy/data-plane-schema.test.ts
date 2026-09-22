import { describe, expect, it } from "vitest";

import {
  assertDataPlaneCompatibility,
  ensureDataPlaneSchema,
  preparePostgresqlDataPlane,
} from "./data-plane-schema";

function fakePool(rows: Array<Record<string, unknown>>) {
  const calls: string[] = [];
  const client = {
    query: async (sql: string) => {
      calls.push(sql.trim());
      if (sql.includes("select schema_version")) return { rows, rowCount: rows.length };
      return { rows: [], rowCount: 0 };
    },
    release: () => undefined,
  };
  return { pool: { connect: async () => client }, calls };
}

describe("data-plane schema runner", () => {
  it("rejeita banco que não expõe os schemas e extensões do Supabase", async () => {
    const { pool } = fakePool([]);
    await expect(assertDataPlaneCompatibility(pool)).rejects.toThrow(
      "data_plane_database_incompatible:auth,storage,extensions,public.vector,extensions.uuid_generate_v4(),extensions.gen_random_bytes(integer)",
    );
  });

  it("exige o contrato de identidade no PostgreSQL operacional", async () => {
    const client = {
      query: async (sql: string) => {
        if (sql.includes("to_regnamespace")) {
          return {
            rows: [{
              vector_type: "vector",
              uuid_generator: "uuid_generate_v4()",
              random_generator: "gen_random_bytes(integer)",
              operational_contract: null,
            }],
            rowCount: 1,
          };
        }
        return { rows: [], rowCount: 0 };
      },
      release: () => undefined,
    };
    const pool = { connect: async () => client };
    await expect(assertDataPlaneCompatibility(pool, "postgresql")).rejects.toThrow(
      "data_plane_database_incompatible:postgresql:public.deskcomm_operational_contract",
    );
  });

  it("prepara o PostgreSQL com os contratos versionados do data plane", async () => {
    const queries: string[] = [];
    await preparePostgresqlDataPlane({
      query: async (sql: string) => {
        queries.push(sql);
        return { rows: [], rowCount: 0 };
      },
    });

    expect(queries).toHaveLength(2);
    expect(queries[0]).toContain("selfhost-prelude.sql");
    expect(queries[1]).toContain("deskcomm_operational_contract");
  });

  it("inicializa e registra a versão dentro da transação", async () => {
    const { pool, calls } = fakePool([]);

    await expect(ensureDataPlaneSchema(pool, { sql: "create table contacts(id uuid)", hash: "h1" })).resolves.toEqual({
      action: "initialized",
      version: 381,
      hash: "h1",
    });
    expect(calls[0]).toBe("begin");
    expect(calls).toContain("commit");
    expect(calls).toContain("create table contacts(id uuid)");
  });

  it("não reaplica o schema quando a versão e o hash já estão iguais", async () => {
    const { pool, calls } = fakePool([{ schema_version: 381, schema_hash: "h1" }]);

    await expect(ensureDataPlaneSchema(pool, { sql: "should not run", hash: "h1" })).resolves.toMatchObject({
      action: "unchanged",
    });
    expect(calls).not.toContain("should not run");
  });

  it("recusa downgrade e alteração silenciosa da mesma versão", async () => {
    const older = fakePool([{ schema_version: 400, schema_hash: "h400" }]);
    await expect(ensureDataPlaneSchema(older.pool, { sql: "x", hash: "h1" })).rejects.toThrow(
      "data_plane_schema_downgrade:400->381",
    );

    const changed = fakePool([{ schema_version: 381, schema_hash: "old" }]);
    await expect(ensureDataPlaneSchema(changed.pool, { sql: "x", hash: "h1" })).rejects.toThrow(
      "data_plane_schema_hash_mismatch:version_requires_new_migration",
    );
  });
});

