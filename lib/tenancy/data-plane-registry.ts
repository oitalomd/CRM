import { Pool } from "pg";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { byteaToBuffer, decryptKey, encryptKey, bufToBytea } from "@/lib/crypto/aes_gcm";
import { createAdminClient } from "@/lib/supabase/admin";
import { DATA_PLANE_SCHEMA_NAME, DATA_PLANE_SCHEMA_VERSION } from "./data-plane-schema";

const READY = "ready" as const;

type DataPlaneStatus = "provisioning" | "ready" | "degraded" | "retiring" | "failed";

interface DataPlaneRow {
  organization_id: string;
  status: DataPlaneStatus;
  connection_uri_encrypted: unknown;
  connection_uri_iv: unknown;
  connection_uri_tag: unknown;
  schema_version: number;
  api_url_encrypted?: unknown;
  api_url_iv?: unknown;
  api_url_tag?: unknown;
  api_key_encrypted?: unknown;
  api_key_iv?: unknown;
  api_key_tag?: unknown;
}

interface RegistryClient {
  from(table: "organization_data_planes"): {
    select(columns: string): {
      eq(
        column: string,
        value: string,
      ): {
        maybeSingle(): Promise<{ data: DataPlaneRow | null; error: { message: string } | null }>;
      };
    };
    upsert(
      values: Record<string, unknown>,
      options?: { onConflict?: string },
    ): Promise<{
      error: { message: string } | null;
    }>;
    update(values: Record<string, unknown>): {
      eq(column: string, value: string): Promise<{ error: { message: string } | null }>;
    };
  };
}

const pools = new Map<string, Pool>();

function registry(client: SupabaseClient): RegistryClient {
  return client as unknown as RegistryClient;
}

function connectionUri(row: DataPlaneRow): string {
  return decryptKey({
    ciphertext: byteaToBuffer(row.connection_uri_encrypted),
    iv: byteaToBuffer(row.connection_uri_iv),
    tag: byteaToBuffer(row.connection_uri_tag),
  });
}

async function readDataPlaneRow(
  organizationId: string,
  admin: SupabaseClient,
): Promise<DataPlaneRow> {
  const { data, error } = await registry(admin)
    .from("organization_data_planes")
    .select(
      "organization_id,status,connection_uri_encrypted,connection_uri_iv,connection_uri_tag,schema_version,api_url_encrypted,api_url_iv,api_url_tag,api_key_encrypted,api_key_iv,api_key_tag",
    )
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (error) throw new Error(`data_plane_registry_read_failed: ${error.message}`);
  if (!data || data.organization_id !== organizationId) {
    throw new Error("data_plane_not_registered");
  }
  return data;
}

function createOrganizationPool(organizationId: string, row: DataPlaneRow): Pool {
  const pool = new Pool({
    connectionString: connectionUri(row),
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    application_name: `deskcomm:${organizationId}`,
  });
  pool.on("error", () => {
    // Pool errors must not crash the Next process. The next request will
    // recreate the pool after invalidation or use the existing healthy pool.
  });
  return pool;
}

/**
 * Grava/atualiza o registro do data plane sem expor a URI.
 * Provisionamento deve chamar isto somente depois de testar a conexão e as
 * migrações do banco dedicado.
 */
export async function registerOrganizationDataPlane(input: {
  organizationId: string;
  connectionUri: string;
  apiUrl?: string;
  apiKey?: string;
  status?: Exclude<DataPlaneStatus, "retiring">;
  schemaVersion?: number;
  admin?: SupabaseClient;
}): Promise<void> {
  const encrypted = encryptKey(input.connectionUri);
  const apiUrl = input.apiUrl ? encryptKey(input.apiUrl) : null;
  const apiKey = input.apiKey ? encryptKey(input.apiKey) : null;
  const { error } = await registry(input.admin ?? createAdminClient())
    .from("organization_data_planes")
    .upsert(
      {
        organization_id: input.organizationId,
        status: input.status ?? "provisioning",
        connection_uri_encrypted: bufToBytea(encrypted.ciphertext),
        connection_uri_iv: bufToBytea(encrypted.iv),
        connection_uri_tag: bufToBytea(encrypted.tag),
        connection_uri_last4: encrypted.last4,
        schema_version: input.schemaVersion ?? 0,
        api_url_encrypted: apiUrl ? bufToBytea(apiUrl.ciphertext) : null,
        api_url_iv: apiUrl ? bufToBytea(apiUrl.iv) : null,
        api_url_tag: apiUrl ? bufToBytea(apiUrl.tag) : null,
        api_key_encrypted: apiKey ? bufToBytea(apiKey.ciphertext) : null,
        api_key_iv: apiKey ? bufToBytea(apiKey.iv) : null,
        api_key_tag: apiKey ? bufToBytea(apiKey.tag) : null,
      },
      { onConflict: "organization_id" },
    );
  if (error) throw new Error(`data_plane_registry_write_failed: ${error.message}`);

  // A replaced URI must not leave a pool using the old database.
  invalidateOrganizationDataPlane(input.organizationId);
}

function dataPlaneApiCredentials(row: DataPlaneRow): { url: string; key: string } {
  if (!row.api_url_encrypted || !row.api_url_iv || !row.api_url_tag ||
      !row.api_key_encrypted || !row.api_key_iv || !row.api_key_tag) {
    throw new Error("data_plane_api_credentials_missing");
  }
  return {
    url: decryptKey({
      ciphertext: byteaToBuffer(row.api_url_encrypted),
      iv: byteaToBuffer(row.api_url_iv),
      tag: byteaToBuffer(row.api_url_tag),
    }),
    key: decryptKey({
      ciphertext: byteaToBuffer(row.api_key_encrypted),
      iv: byteaToBuffer(row.api_key_iv),
      tag: byteaToBuffer(row.api_key_tag),
    }),
  };
}

export async function getOrganizationDataPlaneClient(
  organizationId: string,
  admin: SupabaseClient = createAdminClient(),
): Promise<SupabaseClient> {
  const row = await readDataPlaneRow(organizationId, admin);
  if (row.status !== READY) throw new Error(`data_plane_not_ready:${row.status}`);
  const credentials = dataPlaneApiCredentials(row);
  return createClient(credentials.url, credentials.key, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    global: { headers: { "X-Client-Info": `deskcomm:${organizationId}/data-plane` } },
  });
}

/** Shared-to-dedicated compatibility bridge for a single tenant request. */
export async function getTenantDataClient(
  organizationId: string,
  shared: SupabaseClient,
): Promise<SupabaseClient> {
  try {
    return await getOrganizationDataPlaneClient(organizationId, shared);
  } catch (error) {
    if (error instanceof Error && error.message === "data_plane_not_registered") {
      return shared;
    }
    throw error;
  }
}

/**
 * Resolve the dedicated pool only for a tenant explicitly marked ready.
 * Provisioning, failed and degraded states fail closed.
 */
export async function getOrganizationDataPlanePool(
  organizationId: string,
  admin: SupabaseClient = createAdminClient(),
): Promise<Pool> {
  const cached = pools.get(organizationId);
  if (cached) return cached;

  const data = await readDataPlaneRow(organizationId, admin);
  if (data.status !== READY) {
    throw new Error(`data_plane_not_ready:${data.status}`);
  }

  const pool = createOrganizationPool(organizationId, data);
  pools.set(organizationId, pool);
  return pool;
}

/**
 * Performs the activation gate for a dedicated database.
 *
 * A registry row is never marked ready merely because an URI was submitted:
 * the server must open the database successfully first. The caller is
 * responsible for applying the pinned schema/migrations before invoking this
 * function. On any failure the temporary pool is closed and the row remains
 * non-ready, so application traffic cannot be routed to a partial database.
 */
export async function verifyAndPromoteOrganizationDataPlane(
  organizationId: string,
  admin: SupabaseClient = createAdminClient(),
): Promise<{ organizationId: string; schemaVersion: number; healthcheckedAt: string }> {
  const row = await readDataPlaneRow(organizationId, admin);
  if (row.status === "retiring") {
    throw new Error("data_plane_retiring");
  }

  const pool = createOrganizationPool(organizationId, row);
  const healthcheckedAt = new Date().toISOString();
  try {
    await pool.query("select 1");
    const schema = await pool.query(
      `select schema_version from public.${DATA_PLANE_SCHEMA_NAME} where singleton = true`,
    );
    const schemaVersion = Number(schema.rows[0]?.schema_version);
    if (schemaVersion !== DATA_PLANE_SCHEMA_VERSION) {
      throw new Error(`data_plane_schema_version_mismatch:${schemaVersion || "missing"}`);
    }
    const { error } = await registry(admin)
      .from("organization_data_planes")
      .update({
        status: READY,
        last_healthcheck_at: healthcheckedAt,
        last_error_code: null,
      })
      .eq("organization_id", organizationId);
    if (error) throw new Error(`data_plane_registry_write_failed: ${error.message}`);
    pools.set(organizationId, pool);
    return {
      organizationId,
      schemaVersion: row.schema_version,
      healthcheckedAt,
    };
  } catch (error) {
    await pool.end();
    throw error;
  }
}

export function invalidateOrganizationDataPlane(organizationId: string): void {
  const pool = pools.get(organizationId);
  pools.delete(organizationId);
  if (pool) void pool.end();
}

export async function closeOrganizationDataPlanePools(): Promise<void> {
  const active = [...pools.values()];
  pools.clear();
  await Promise.all(active.map((pool) => pool.end()));
}

