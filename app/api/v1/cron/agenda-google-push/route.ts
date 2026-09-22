import { NextResponse, type NextRequest } from "next/server";
import { googlePushCandidates } from "@/lib/agenda/google/candidates";
import { apenasDeMembrosAtivos } from "@/lib/agenda/google/membros";
import { reconcileAppointment } from "@/lib/agenda/google/sync-executor";
import { audit } from "@/lib/audit";
import { env } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";
export const dynamic = "force-dynamic";
interface GooglePushCandidate {
  id: string;
  organization_id: string;
  user_id: string;
}
async function executar(req: NextRequest) {
  if (
    ![env.INTERNAL_CRON_SECRET, env.INTERNAL_SECRET]
      .filter(Boolean)
      .some((s) => req.headers.get("authorization") === `Bearer ${s}`)
  )
    return NextResponse.json(
      { error: { code: "unauthenticated", message: "cron secret inválido" } },
      { status: 401 },
    );
  const db = createAdminClient();
  const { data: organizations, error: organizationsError } = await db
    .from("organizations")
    .select("id")
    .limit(25);
  if (organizationsError)
    return NextResponse.json(
      { error: { code: "internal_error", message: "Não foi possível ler as organizações." } },
      { status: 500 },
    );
  const dataClientByOrg = new Map<string, ReturnType<typeof createAdminClient>>();
  const candidates: GooglePushCandidate[] = [];
  for (const organization of organizations ?? []) {
    try {
      const dataClient = await getTenantDataClient(organization.id, db);
      dataClientByOrg.set(organization.id, dataClient);
      const { data, error } = await googlePushCandidates(dataClient, organization.id);
      if (error) throw error;
      candidates.push(...((data ?? []) as GooglePushCandidate[]));
    } catch {
      // Falha de um tenant fica isolada e será reprocessada na próxima rodada.
    }
  }
  const effects = new Map<string, { processados: number; falhas: number }>();
  const active = await apenasDeMembrosAtivos(db, candidates);
  for (const item of active) {
    const dataClient = dataClientByOrg.get(item.organization_id);
    if (!dataClient) continue;
    let result: string;
    try {
      result = await reconcileAppointment(dataClient, item.organization_id, item.id);
    } catch {
      result = "failed";
    }
    if (result === "busy" || result === "unchanged" || result === "terminal") continue;
    const summary = effects.get(item.organization_id) ?? { processados: 0, falhas: 0 };
    if (result === "processed") summary.processados++;
    else summary.falhas++;
    effects.set(item.organization_id, summary);
  }
  for (const [organizationId, summary] of effects) {
    if (summary.processados > 0 || summary.falhas > 0)
      await audit({
        action: "agenda.google.sync_executado",
        organizationId,
        metadata: { direcao: "ida", ...summary },
      });
  }
  return NextResponse.json({ data: { candidatos: candidates.length, organizacoes: effects.size } });
}
export const GET = executar;
export const POST = executar;

