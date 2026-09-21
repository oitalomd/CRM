import type { SupabaseClient } from "@supabase/supabase-js";
import { Pool } from "pg";

import { byteaToBuffer, decryptKey, encryptKey, bufToBytea } from "@/lib/crypto/aes_gcm";
import { createAdminClient } from "@/lib/supabase/admin";

const READY = "ready" as const;

type DataPlaneStatus = "provisioning" | "ready" | "degraded" | "retiring" | "failed";

interface DataPlaneRow {
  organization_id: string;
  status: DataPlaneStatus;
  connection_uri_encrypted: unknown;
  connection_uri_iv: unknown;
  connection_uri_tag: unknown;
  schema_version: number;
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

/**
 * Grava/atualiza o registro do data plane sem expor a URI.
 * Provisionamento deve chamar isto somente depois de testar a conexão e as
 * migrações do banco dedicado.
 */
export async function registerOrganizationDataPlane(input: {
  organizationId: string;
  connectionUri: string;
  status?: Exclude<DataPlaneStatus, "retiring">;
  schemaVersion?: number;
  admin?: SupabaseClient;
}): Promise<void> {
  const encrypted = encryptKey(input.connectionUri);
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
      },
      { onConflict: "organization_id" },
    );
  if (error) throw new Error(`data_plane_registry_write_failed: ${error.message}`);

  // A replaced URI must not leave a pool using the old database.
  invalidateOrganizationDataPlane(input.organizationId);
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

  const { data, error } = await registry(admin)
    .from("organization_data_planes")
    .select(
      "organization_id,status,connection_uri_encrypted,connection_uri_iv,connection_uri_tag,schema_version",
    )
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (error) throw new Error(`data_plane_registry_read_failed: ${error.message}`);
  if (!data || data.organization_id !== organizationId) {
    throw new Error("data_plane_not_registered");
  }
  if (data.status !== READY) {
    throw new Error(`data_plane_not_ready:${data.status}`);
  }

  const pool = new Pool({
    connectionString: connectionUri(data),
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    application_name: `deskcomm:${organizationId}`,
  });
  pool.on("error", () => {
    // Pool errors must not crash the Next process. The next request will
    // recreate the pool after invalidation or use the existing healthy pool.
  });
  pools.set(organizationId, pool);
  return pool;
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

