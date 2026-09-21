import { randomUUID } from "node:crypto";
import { type NextRequest } from "next/server";
import { z } from "zod";

import { audit } from "@/lib/audit";
import { fail, ok } from "@/lib/api/wrappers";
import { requirePlatformAdmin } from "@/lib/auth/requirePlatformAdmin";
import { mfaEmDivida } from "@/lib/auth/server";
import {
  registerOrganizationDataPlane,
  verifyAndPromoteOrganizationDataPlane,
} from "@/lib/tenancy/data-plane-registry";
import { createAdminClient } from "@/lib/supabase/admin";

const connectionUri = z
  .string()
  .trim()
  .min(20)
  .max(2048)
  .refine((value) => value.startsWith("postgres://") || value.startsWith("postgresql://"), {
    message: "connection_uri deve usar postgres:// ou postgresql://",
  });
const apiUrl = z.string().trim().url().max(2048);
const apiKey = z.string().trim().min(20).max(4096);

const dataPlaneAction = z.discriminatedUnion("action", [
  z.object({
    action: z.literal("register"),
    connection_uri: connectionUri,
    api_url: apiUrl,
    api_key: apiKey,
    schema_version: z.number().int().min(0).default(0),
  }),
  z.object({ action: z.literal("promote") }),
]);

type DataPlaneSafeRow = {
  organization_id: string;
  status: string;
  connection_uri_last4: string;
  schema_version: number;
  last_healthcheck_at: string | null;
  last_migration_at: string | null;
  last_error_code: string | null;
  created_at: string;
  updated_at: string;
};

function safeRow(row: unknown): DataPlaneSafeRow | null {
  return row && typeof row === "object" ? (row as DataPlaneSafeRow) : null;
}

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const requestId = randomUUID();
  const { id } = await params;
  try {
    await requirePlatformAdmin();
  } catch {
    return fail("forbidden", "Platform admin required", 403, { requestId });
  }

  const { data, error } = await createAdminClient()
    .from("organization_data_planes")
    .select(
      "organization_id,status,connection_uri_last4,schema_version,last_healthcheck_at,last_migration_at,last_error_code,created_at,updated_at",
    )
    .eq("organization_id", id)
    .maybeSingle();
  if (error) return fail("internal_error", "Não foi possível ler o data plane", 500, { requestId });
  return ok(safeRow(data), { requestId });
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> },
) {
  const requestId = randomUUID();
  const { id } = await params;
  let adminCtx: Awaited<ReturnType<typeof requirePlatformAdmin>>;
  try {
    adminCtx = await requirePlatformAdmin();
  } catch {
    return fail("forbidden", "Platform admin required", 403, { requestId });
  }
  if (adminCtx.platformAdmin.scope !== "full") {
    return fail("forbidden", "Seu acesso não permite administrar data planes", 403, { requestId });
  }
  if (await mfaEmDivida()) {
    return fail("mfa_required", "Confirme a verificação em duas etapas", 403, { requestId });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return fail("validation_error", "Invalid JSON body", 400, { requestId });
  }
  const parsed = dataPlaneAction.safeParse(body);
  if (!parsed.success) {
    return fail("validation_error", "Ação de data plane inválida", 400, {
      requestId,
      details: parsed.error.flatten(),
    });
  }

  try {
    if (parsed.data.action === "register") {
      await registerOrganizationDataPlane({
        organizationId: id,
        connectionUri: parsed.data.connection_uri,
        apiUrl: parsed.data.api_url,
        apiKey: parsed.data.api_key,
        status: "provisioning",
        schemaVersion: parsed.data.schema_version,
      });
      void audit({
        action: "platform_admin.tenant_data_plane_registered",
        actorUserId: adminCtx.user.id,
        actingAsPlatformAdmin: true,
        bypassedRls: true,
        organizationId: id,
        resourceType: "organization_data_plane",
        resourceId: id,
        requestId,
        metadata: { schema_version: parsed.data.schema_version },
      });
      return ok({ status: "provisioning" }, { status: 201, requestId });
    }

    const result = await verifyAndPromoteOrganizationDataPlane(id);
    void audit({
      action: "platform_admin.tenant_data_plane_promoted",
      actorUserId: adminCtx.user.id,
      actingAsPlatformAdmin: true,
      bypassedRls: true,
      organizationId: id,
      resourceType: "organization_data_plane",
      resourceId: id,
      requestId,
      metadata: { schema_version: result.schemaVersion },
    });
    return ok({ status: "ready", ...result }, { requestId });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown";
    if (message === "data_plane_not_registered") {
      return fail("not_found", "Data plane não registrado", 404, { requestId });
    }
    // Não devolve a mensagem do driver: ela pode conter host, usuário ou
    // detalhes da URI. O erro completo fica nos logs protegidos do servidor.
    return fail("data_plane_unavailable", "Não foi possível validar o banco dedicado", 503, {
      requestId,
    });
  }
}

