/**
 * GET/POST /api/v1/cron/followup-flow-worker — Onda 4 (Task 4.2) + Onda 8
 * (Task 8.1, gatilho de silêncio).
 *
 * Drena os enrollments due de `followup_enrollments` via `runFollowupTick`
 * (lib/followup/engine.ts) — o motor único de relógio do sistema de
 * follow-up. Trigger Postgres NUNCA faz HTTP; este cron TS é quem consome via
 * admin client, no mesmo contrato dos demais crons.
 *
 * Depois do tick, `runSilenceSweep` (lib/followup/silence-sweep.ts) NO MESMO
 * tick — gatilho TIME-DRIVEN (varredura periódica, não event-driven): acha
 * pointers `trigger_config.kind='silence'` ativos, gateia via
 * `isPointerEnabledForAutomaticTrigger` (só enrolla se algum agente publicado
 * da org tem o pointer habilitado), acha contatos silenciosos e cria
 * enrollment. Falha do sweep NUNCA aborta a resposta do tick (try/catch
 * isolado, só loga) — o cron sempre devolve o resultado de `runFollowupTick`.
 *
 * No fim, drena texto fixo pendente (`enviarTextoFixoPendente`) — o mesmo
 * atalho do relógio HTTP. Onde não há `agent-worker` (instalação sem o
 * contêiner `worker`), sem isto o job `followup_turn` fica `pending` e o
 * no_reply nunca vira mensagem. O ledger (job_id, seq) impede envio em dobro no
 * self-host, onde o worker também consome a fila.
 *
 * Auth: Bearer INTERNAL_CRON_SECRET|INTERNAL_SECRET, fail-closed. Audit
 * agregada por tick (`followup.worker_run` + `followup.silence_sweep_run`),
 * sem organization_id (roda pra todas as orgs).
 */
import { randomUUID } from "node:crypto";
import type { NextRequest } from "next/server";

import { ok, fail } from "@/lib/api/wrappers";
import { audit } from "@/lib/audit";
import { env } from "@/lib/env";
import { logger } from "@/lib/logger";
import { createAdminClient } from "@/lib/supabase/admin";
import { createSupabaseAdminClient, runFollowupTick, type FollowupJobRequest } from "@/lib/followup/engine";
import { createSupabaseFollowupGateDb } from "@/lib/followup/agent-followup-gate";
import { enviarTextoFixoPendente } from "@/lib/followup/enviar-texto-fixo";
import { createSupabaseSilenceSweepDb, runSilenceSweep } from "@/lib/followup/silence-sweep";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";

export const dynamic = "force-dynamic";

/** Insere o job followup_turn na fila existente (migration 0050) — consumido
 *  pelo handler já pronto em lib/agent-engine/agent/followup-turn.ts. */
async function enqueueJob(admin: ReturnType<typeof createAdminClient>, job: FollowupJobRequest): Promise<void> {
  const { error } = await admin.from("job_queue").insert({
    organization_id: job.organization_id,
    contact_id: job.contact_id,
    kind: "followup_turn",
    payload: job.payload,
  });
  if (error) throw new Error(error.message);
}

function somaTick(a: { claim_falhou?: boolean; claimed: number; advanced: number; scheduled: number; failed: number; dead: number }, b: typeof a) {
  return {
    claim_falhou: Boolean(a.claim_falhou || b.claim_falhou),
    claimed: a.claimed + b.claimed,
    advanced: a.advanced + b.advanced,
    scheduled: a.scheduled + b.scheduled,
    failed: a.failed + b.failed,
    dead: a.dead + b.dead,
  };
}

async function handle(req: NextRequest): Promise<Response> {
  const requestId = randomUUID();

  const auth = req.headers.get("authorization") ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";
  const provided = bearer || (req.headers.get("x-cron-secret")?.trim() ?? "");
  const accepted = [env.INTERNAL_CRON_SECRET, env.INTERNAL_SECRET].filter(Boolean);
  if (accepted.length === 0 || !provided || !accepted.includes(provided)) {
    return fail("forbidden", "Cron secret missing or invalid.", 403, { requestId });
  }

  const controlPlane = createAdminClient();
  const { data: organizations, error: organizationsError } = await controlPlane
    .from("organizations")
    .select("id")
    .limit(50);
  if (organizationsError) return fail("internal_error", "Não foi possível listar as organizações.", 500, { requestId });

  let summary = { claim_falhou: false, claimed: 0, advanced: 0, scheduled: 0, failed: 0, dead: 0 };
  let confirmationNotices = 0;
  const orgsWithError: string[] = [];

  for (const organization of organizations ?? []) {
    const organizationId = organization.id as string;
    try {
      const dataClient = await getTenantDataClient(organizationId, controlPlane);
      const confirmation = await dataClient.rpc("fn_appointment_confirmation_sweep", {});
      if (confirmation.error) throw confirmation.error;
      confirmationNotices += Number(confirmation.data ?? 0);

      const deps = {
        db: createSupabaseAdminClient(dataClient),
        clock: () => new Date(),
        enqueueJob: (job: FollowupJobRequest) => enqueueJob(dataClient, job),
      };
      summary = somaTick(summary, await runFollowupTick(deps));

      const sweepSummary = await runSilenceSweep({
        db: createSupabaseSilenceSweepDb(dataClient),
        gateDb: createSupabaseFollowupGateDb(dataClient),
        clock: () => new Date(),
      });
      if (sweepSummary.enrolled || sweepSummary.pointers_gated_out || sweepSummary.skipped_existing) {
        void audit({ action: "followup.silence_sweep_run", organizationId, bypassedRls: true, metadata: { ...sweepSummary }, requestId });
      }

      try {
        await enviarTextoFixoPendente(dataClient);
      } catch (err) {
        logger.error("[followup-flow-worker.cron] enviarTextoFixoPendente threw", {
          error: err instanceof Error ? err.message : String(err), organizationId, requestId,
        });
      }
    } catch (err) {
      orgsWithError.push(organizationId);
      logger.error("[followup-flow-worker.cron] organização falhou", {
        error: err instanceof Error ? err.message : String(err), organizationId, requestId,
      });
    }
  }

  if (confirmationNotices > 0) {
    void audit({ action: "agenda.confirmation_sweep_run", organizationId: null, bypassedRls: true, requestId, metadata: { avisos: confirmationNotices } });
  }

  // Só audita tick que MEXEU em alguma coisa. Auditar toda batida enchia o
  // api_audit_log — que é append-only e tem retenção de 5 anos — de linhas
  // vazias: numa instalação parada, medido nesta VPS, 95% das entradas eram
  // heartbeat de cron (1.175 de 1.236 em ~9h), afogando as ações reais na tela
  // de auditoria. Liveness de worker é assunto de log/monitoramento, não de
  // trilha de auditoria.
  //
  // `claim_falhou` entra na condição porque é o ÚNICO caso em que todos os
  // contadores são zero e ainda assim algo aconteceu: o claim não chegou ao
  // banco. Sem esta cláusula o tick que falhou é idêntico, na trilha, ao tick de
  // uma instalação sem nada a fazer.
  //
  // O emissor NUNCA foi o buraco: `claim_falhou` e o `logger.error` existem em
  // `runFollowupTick` desde f66f0ddb, com teste. O que faltava era o outro lado
  // — anti-pattern 3 do CLAUDE.md, evento sem consumer: o campo criado para
  // separar "o banco não respondeu" de "não havia nada a fazer" era emitido e
  // ninguém o lia. Quem vier depois precisa saber onde estava o defeito, senão
  // vai procurar no lugar que já estava certo.
  if (
    summary.claim_falhou ||
    summary.claimed ||
    summary.advanced ||
    summary.scheduled ||
    summary.failed ||
    summary.dead
  ) {
    void audit({
      action: "followup.worker_run",
      organizationId: null,
      bypassedRls: true,
      metadata: { ...summary },
      requestId,
    });
  }

  return ok({ ...summary, organizations: organizations?.length ?? 0, orgs_with_error: orgsWithError.length }, { requestId });
}

export async function GET(req: NextRequest): Promise<Response> {
  return handle(req);
}

export async function POST(req: NextRequest): Promise<Response> {
  return handle(req);
}

