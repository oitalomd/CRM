/**
 * GET/POST /api/v1/cron/snooze-watcher — Onda 5.3 (snooze por conversa).
 *
 * Varre conversas com `snooze_until` vencido (<= now). Para cada uma, limpa
 * o snooze SEMPRE (evita reprocessar no próximo tick). Se o lead NÃO
 * respondeu desde que o snooze foi criado (last_inbound_at <= snoozed_at, ou
 * nunca respondeu) e a conversa não está closed/archived, reabre
 * (status='open') e cria um aviso interno `snooze_expired` — nada é enviado
 * ao cliente.
 *
 * Auth: mesmo contrato dos demais crons (Bearer INTERNAL_CRON_SECRET|
 * INTERNAL_SECRET, fail-closed).
 *
 * NOTA DE DEPLOY: não há `vercel.json` neste repo (self-host). O kit
 * self-host precisa agendar esta rota (ex.: a cada 5 min) no container
 * `scheduler` com o Bearer secret configurado — sem isso o snooze nunca
 * expira sozinho.
 */
import { randomUUID } from "node:crypto";
import type { NextRequest } from "next/server";

import { ok, fail } from "@/lib/api/wrappers";
import { audit } from "@/lib/audit";
import { env } from "@/lib/env";
import { logger } from "@/lib/logger";
import { createAdminClient } from "@/lib/supabase/admin";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";

export const dynamic = "force-dynamic";

/** Max conversas processadas por invocação (safety cap). */
const SCAN_LIMIT = 200;

interface DueConversation {
  id: string;
  organization_id: string;
  snoozed_at: string | null;
  last_inbound_at: string | null;
  status: string;
}

async function handle(req: NextRequest): Promise<Response> {
  const requestId = randomUUID();

  const auth = req.headers.get("authorization") ?? "";
  const provided = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";
  const accepted = [env.INTERNAL_CRON_SECRET, env.INTERNAL_SECRET].filter(Boolean);
  if (accepted.length === 0 || !provided || !accepted.includes(provided)) {
    return fail("forbidden", "Cron secret missing or invalid.", 403, { requestId });
  }

  const admin = createAdminClient();
  const nowIso = new Date().toISOString();

  const { data: organizations, error: organizationsError } = await admin
    .from("organizations")
    .select("id");
  if (organizationsError) {
    logger.error("[snooze-watcher] failed to list organizations", {
      error: organizationsError.message,
      requestId,
    });
    return fail("internal_error", "Failed to query organizations.", 500, { requestId });
  }

  const conversations: DueConversation[] = [];
  const dataClientByOrg = new Map<string, ReturnType<typeof createAdminClient>>();
  for (const organization of organizations ?? []) {
    let dataClient: ReturnType<typeof createAdminClient>;
    try {
      dataClient = await getTenantDataClient(organization.id, admin);
    } catch (err) {
      logger.warn("[snooze-watcher] data plane unavailable; organization skipped", {
        organizationId: organization.id,
        error: err instanceof Error ? err.message : String(err),
        requestId,
      });
      continue;
    }
    dataClientByOrg.set(organization.id, dataClient);

    const { data: due, error: queryError } = await dataClient
      .from("conversations")
      .select("id, organization_id, snoozed_at, last_inbound_at, status")
      .eq("organization_id", organization.id)
      .not("snooze_until", "is", null)
      .lte("snooze_until", nowIso)
      .limit(SCAN_LIMIT);
    if (queryError) {
      logger.error("[snooze-watcher] query by organization failed", {
        organizationId: organization.id,
        error: queryError.message,
        requestId,
      });
      continue;
    }
    conversations.push(...((due ?? []) as DueConversation[]));
  }
  conversations.splice(SCAN_LIMIT);
  let reopened = 0;

  for (const c of conversations) {
    // Comparar como Date, não string: dois timestamptz ISO com formatos sutilmente
    // diferentes (Z vs +00:00, frações de precisão distinta) quebrariam a ordem
    // lexicográfica — e esta comparação decide se a conversa reabre.
    const leadReplied = !!(
      c.last_inbound_at &&
      c.snoozed_at &&
      new Date(c.last_inbound_at).getTime() > new Date(c.snoozed_at).getTime()
    );
    const clear = { snooze_until: null, snoozed_at: null, snoozed_by_user_id: null };
    const willReopen = !leadReplied && c.status !== "closed" && c.status !== "archived";
    const fields = willReopen ? { ...clear, status: "open", last_message_at: nowIso } : clear;
    const dataClient = dataClientByOrg.get(c.organization_id);
    if (!dataClient) continue;

    // O clear É o claim atômico: `.not("snooze_until","is",null)` garante que só
    // quem ainda vê o snooze não-nulo processa a row. Se dois ticks concorrentes
    // (double-schedule / curl manual durante o cron) leem a mesma row, só o
    // primeiro atualiza — o segundo recebe 0 linhas e pula, sem aviso duplicado.
    const { data: claimed } = await dataClient
      .from("conversations")
      .update(fields)
      .eq("id", c.id)
      .not("snooze_until", "is", null)
      .select("id")
      .maybeSingle();
    if (!claimed) continue; // outro tick já processou esta conversa

    if (willReopen) {
      await dataClient.from("agent_inbox_items").insert({
        organization_id: c.organization_id,
        kind: "snooze_expired",
        severity: "warn",
        title: "Lead não respondeu no prazo",
        ref_kind: "conversation",
        ref_id: c.id,
      });
      reopened++;
    }
  }

  // Ver comentário em followup-flow-worker: varredura que não reabriu nada não
  // é mutação, e não tem por que ocupar linha na auditoria.
  if (reopened > 0) {
    void audit({
      action: "conversation.snooze_watcher_run",
      organizationId: null,
      bypassedRls: true,
      metadata: { scanned: conversations.length, reopened },
      requestId,
    });
  }

  return ok({ scanned: conversations.length, reopened }, { requestId });
}

export async function GET(req: NextRequest): Promise<Response> {
  return handle(req);
}

export async function POST(req: NextRequest): Promise<Response> {
  return handle(req);
}

