import { randomUUID } from "node:crypto";
import { env } from "@/lib/env";
import { ok, fail } from "@/lib/api/wrappers";
import { getRequestPool } from "@/lib/agent-engine/db/request-pool";
import { createAdminClient } from "@/lib/supabase/admin";
import { tickProspecting } from "@/lib/prospecting/worker";
import { logger } from "@/lib/logger";
import { getOrganizationDataPlanePool, getTenantDataClient } from "@/lib/tenancy/data-plane-registry";

export const dynamic = "force-dynamic";
export const maxDuration = 300;
async function handle(req: Request) {
  const requestId = randomUUID();
  const value = /^Bearer (.+)$/.exec(req.headers.get("authorization") ?? "")?.[1];
  const accepted = [env.INTERNAL_CRON_SECRET, env.INTERNAL_SECRET].filter(Boolean);
  if (!value || !accepted.includes(value))
    return fail("forbidden", "Credencial de execução inválida.", 403, { requestId });
  const controlPlane = createAdminClient();
  try {
    const { data: organizations, error } = await controlPlane.from("organizations").select("id").limit(50);
    if (error) return fail("internal_error", "Não foi possível listar as organizações.", 500, { requestId });
    let processed = 0;
    let orgsWithError = 0;
    for (const organization of organizations ?? []) {
      const organizationId = organization.id as string;
      try {
        const dataClient = await getTenantDataClient(organizationId, controlPlane);
        let pool;
        try {
          pool = await getOrganizationDataPlanePool(organizationId, controlPlane);
        } catch (poolError) {
          if (poolError instanceof Error && poolError.message === "data_plane_not_registered") pool = getRequestPool();
          else throw poolError;
        }
        const result = await tickProspecting(pool, dataClient, { organizationId });
        processed += result.processed;
      } catch (err) {
        orgsWithError++;
        logger.error("[prospecting.cron] organização falhou", {
          organizationId, error: err instanceof Error ? err.message : String(err), requestId,
        });
      }
    }
    return ok({ processed, organizations: organizations?.length ?? 0, orgs_with_error: orgsWithError }, { requestId });
  } catch (err) {
    // O `catch` era SEM PARÂMETRO: o objeto do erro não ficava de fora do log,
    // ele era DESCARTADO — não existia em variável nenhuma. Num cron, que roda
    // sozinho e sem ninguém olhando, isso significava que a prospecção da
    // instalação inteira podia parar e a única evidência ser um 500 numa
    // resposta que ninguém lê.
    const detalhe = err instanceof Error ? err.message : String(err);
    logger.error("[prospecting.cron] tickProspecting lançou", { error: detalhe, requestId });
    // O detalhe vai na resposta, como o routing-worker faz: quem chama o cron à
    // mão para investigar merece ler a causa, não uma frase genérica.
    return fail("internal_error", detalhe, 500, { requestId });
  }
}
export const GET = handle;
export const POST = handle;

