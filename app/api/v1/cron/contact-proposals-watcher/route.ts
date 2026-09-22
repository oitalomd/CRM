/**
 * Cron — fecha as propostas de dado que ninguém decidiu (spec 17 §4b).
 *
 * A 0123 fez `expires_at` obrigatório. **Prazo que ninguém cobre é pior que
 * prazo nenhum**: promete um limite que não existe, e a pendência fica na ficha
 * para sempre — um badge permanente que simula atenção e adia a decisão em vez
 * de cobrá-la. Esta rota é quem cumpre a promessa daquela coluna.
 *
 * ⚠️ AS ORGS SAEM DE `contact_field_proposals`, NÃO DE `crm_leads`.
 *
 * A tentação era pendurar isto no `risk-watcher`, que já varre organizações no
 * mesmo tick. Mas ele lista quem tem LEAD ABERTO — e uma organização pode ter
 * proposta pendente sem nenhum negócio no funil (contato que só conversou).
 * Nessas, a proposta nunca venceria, e o sintoma seria invisível: "nada
 * venceu" tem a mesma cara de "nada vencia ainda".
 *
 * Rota própria e AGENDADA no mesmo commit: `tests/unit/cron-routes-scheduled.test.ts`
 * compara o diretório de rotas com o crontab e fica vermelho se alguma ficar
 * órfã. O comentário do `risk-watcher` conta o que acontece sem isso — uma rota
 * com teste e doc que ninguém chamava, por meses.
 */
import { randomUUID } from "node:crypto";
import type { NextRequest } from "next/server";

import { ok, fail } from "@/lib/api/wrappers";
import { vencePropostasDeDado } from "@/lib/contacts/proposta-de-dado";
import { env } from "@/lib/env";
import { logger } from "@/lib/logger";
import { createAdminClient } from "@/lib/supabase/admin";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";

export const dynamic = "force-dynamic";

/** Teto por invocação — a próxima passada pega o resto. */
const ORG_LIMIT = 50;

async function handle(req: NextRequest): Promise<Response> {
  const requestId = randomUUID();

  const auth = req.headers.get("authorization") ?? "";
  const provided = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";
  const accepted = [env.INTERNAL_CRON_SECRET, env.INTERNAL_SECRET].filter(Boolean);
  if (accepted.length === 0 || !provided || !accepted.includes(provided)) {
    return fail("forbidden", "Cron secret missing or invalid.", 403, { requestId });
  }

  const admin = createAdminClient();
  const agora = new Date();

  const { data: organizations, error: organizationsError } = await admin
    .from("organizations")
    .select("id")
    .limit(ORG_LIMIT);
  if (organizationsError) {
    logger.error("[contact-proposals-watcher] falha ao listar organizações", {
      error: organizationsError.message,
      requestId,
    });
    return fail("internal_error", "Failed to list organizations.", 500, { requestId });
  }

  let vencidas = 0;
  let itens = 0;
  const comErro: string[] = [];

  for (const organization of organizations ?? []) {
    const org = organization.id as string;
    try {
      const dataClient = await getTenantDataClient(org, admin);
      // Só quem TEM proposta vencida é processado. A descoberta e o vencimento
      // ficam no mesmo tenant; nenhum dado de uma organização atravessa o loop.
      const { data: pending, error: pendingError } = await dataClient
        .from("contact_field_proposals")
        .select("id")
        .eq("organization_id", org)
        .eq("status", "pending")
        .lt("expires_at", agora.toISOString())
        .limit(1);
      if (pendingError) throw pendingError;
      if (!pending?.length) continue;

      const r = await vencePropostasDeDado(dataClient, org, agora);
      vencidas += r.vencidas;
      itens += r.itensDeCaixa;
    } catch (e) {
      // Uma org que falha NÃO derruba as outras: um tenant com dado estranho
      // congelaria o vencimento de todos, e o sintoma ("nada venceu") seria
      // indistinguível de "não havia o que vencer".
      comErro.push(org);
      logger.error("[contact-proposals-watcher] org falhou", {
        organizationId: org,
        error: e instanceof Error ? e.message : String(e),
        requestId,
      });
    }
  }

  return ok(
    {
      organizations: (organizations ?? []).length,
      proposals_expired: vencidas,
      inbox_items: itens,
      orgs_with_error: comErro.length,
    },
    { requestId },
  );
}

export async function GET(req: NextRequest): Promise<Response> {
  return handle(req);
}

export async function POST(req: NextRequest): Promise<Response> {
  return handle(req);
}

