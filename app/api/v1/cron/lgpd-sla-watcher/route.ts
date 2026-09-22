/**
 * GET /api/v1/cron/lgpd-sla-watcher
 *
 * Daily cron (09:00 BRT / 12:00 UTC) — scans active lgpd_requests and fires
 * SLA alarms when requests are approaching / past their threshold:
 *   - data_request  → alarm if received_at <= now - 5 days  (D+5)
 *   - redact / store_redact → alarm if received_at <= now - 10 days (D+10)
 *
 * Auth: `Authorization: Bearer <INTERNAL_CRON_SECRET|INTERNAL_SECRET>` (fail-closed).
 * Audit: emite `lgpd.sla_watcher_run` quando houve alarme, dedup ou erro — tick
 *   de instalação sem solicitação vencida NÃO audita (ver a guarda "cron que não
 *   fez nada não audita", vigiada por `cron-audita-so-quando-ha-efeito.test.ts`).
 *
 * MVP: calendar-day approximation for SELECT is intentional and acceptable
 * (D+5 corridos ≈ D+5 úteis in short windows). Precision via computeDueAt
 * deferred to v2.
 */
import { randomUUID } from "node:crypto";
import type { NextRequest } from "next/server";

import { ok, fail } from "@/lib/api/wrappers";
import { env } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";
import { audit } from "@/lib/audit";
import { triggerSlaAlarm } from "@/lib/lgpd/sla-alarm";
import { marcaDaSaida, type MarcaDeSaida } from "@/lib/branding/saida";
import type { LgpdRequest } from "@/lib/lgpd/types";
import type { AlarmThreshold } from "@/lib/lgpd/sla-alarm";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";
import type { SupabaseClient } from "@supabase/supabase-js";

export const dynamic = "force-dynamic";

/** Max requests processed per cron invocation (safety cap). */
const SCAN_LIMIT = 500;

interface OrgRow {
  id: string;
  dpo_email: string | null;
  display_name: string | null;
}

type RequestCandidate = { request: LgpdRequest; organization: OrgRow; dataClient: SupabaseClient };

export async function GET(req: NextRequest): Promise<Response> {
  const requestId = randomUUID();
  const startedAt = Date.now();

  // ────────────────────────────────────────────────────────────────────────
  // Auth — Bearer INTERNAL_CRON_SECRET or INTERNAL_SECRET (fail-closed)
  // ────────────────────────────────────────────────────────────────────────
  const auth = req.headers.get("authorization") ?? "";
  const provided = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";

  const cronSecret = env.INTERNAL_CRON_SECRET;
  const fallbackSecret = env.INTERNAL_SECRET;
  const accepted: string[] = [];
  if (cronSecret) accepted.push(cronSecret);
  if (fallbackSecret) accepted.push(fallbackSecret);

  if (accepted.length === 0 || !provided || !accepted.includes(provided)) {
    return fail("forbidden", "Cron secret missing or invalid.", 403, { requestId });
  }

  const controlPlane = createAdminClient();
  const { data: organizations, error: organizationsError } = await controlPlane
    .from("organizations")
    .select("id, dpo_email, display_name")
    .limit(50);
  if (organizationsError) return fail("internal_error", "Failed to list organizations.", 500, { requestId });

  const candidates: RequestCandidate[] = [];
  for (const organization of (organizations ?? []) as OrgRow[]) {
    try {
      const dataClient = await getTenantDataClient(organization.id, controlPlane);
      const { data: rows, error } = await dataClient
        .from("lgpd_requests")
        .select("*")
        .eq("organization_id", organization.id)
        .not("status", "in", '("completed","failed")')
        .or(
          [
            "and(request_type.eq.data_request,received_at.lte." + new Date(Date.now() - 5 * 86_400_000).toISOString() + ")",
            "and(request_type.in.(redact,store_redact),received_at.lte." + new Date(Date.now() - 10 * 86_400_000).toISOString() + ")",
          ].join(","),
        )
        .limit(SCAN_LIMIT);
      if (error) throw error;
      for (const row of rows ?? []) candidates.push({ request: row as LgpdRequest, organization, dataClient });
    } catch (err) {
      console.error("[lgpd-sla-watcher] organization query failed", organization.id, err);
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // Process each request
  // ────────────────────────────────────────────────────────────────────────
  let alarmedCount = 0;
  let dedupedCount = 0;
  let errorsCount = 0;

  // Uma organização pode ter muitas solicitações vencidas no mesmo lote (o teto
  // é 500), e a marca dela é a mesma para todas. Sem esta memória o cron faria
  // uma leitura de `organizations.settings` por LINHA para devolver o mesmo
  // objeto. Vive só dentro desta invocação de propósito: o próximo ciclo (12h
  // depois) tem de reler, senão uma troca de marca demoraria meio dia a valer.
  const marcaPorOrg = new Map<string, MarcaDeSaida>();
  const marcaDe = async (orgId: string): Promise<MarcaDeSaida> => {
    const guardada = marcaPorOrg.get(orgId);
    if (guardada) return guardada;
    const resolvida = await marcaDaSaida(orgId);
    marcaPorOrg.set(orgId, resolvida);
    return resolvida;
  };

  for (const candidate of candidates) {
    const { request: lgpdRequest, organization, dataClient } = candidate;
    const threshold: AlarmThreshold = lgpdRequest.request_type === "data_request" ? "data_request_d5" : "redact_d10";

    try {
      const result = await triggerSlaAlarm({
        request: lgpdRequest,
        threshold,
        organizationDpoEmail: organization.dpo_email,
        organizationName: organization.display_name,
        marca: await marcaDe(lgpdRequest.organization_id),
        dataClient,
      });

      if (result.reason === "dedup_24h") {
        dedupedCount++;
      } else if (result.alarmed) {
        alarmedCount++;
      } else {
        // alarmed=false but no dedup reason — both sentry + email failed
        errorsCount++;
      }
    } catch (err) {
      errorsCount++;
      console.error("[lgpd-sla-watcher] triggerSlaAlarm threw for request", lgpdRequest.id, err);
    }
  }

  const durationMs = Date.now() - startedAt;
  const scanned = candidates.length;

  // ────────────────────────────────────────────────────────────────────────
  // Master audit entry (fire-and-forget)
  // ────────────────────────────────────────────────────────────────────────
  // Varredura que não achou solicitação vencida não é mutação e não ocupa linha
  // de auditoria (mesmo critério do snooze-watcher e do recover-stuck-messages).
  //
  // `deduped` ENTRA na condição, e aqui a régua é mais generosa que nos irmãos
  // de propósito: dedup significa que existe prazo LGPD estourado sendo
  // reencontrado, e num caminho de compliance o registro de que o alarme
  // continua de pé vale mais que a linha economizada. O que sai é só o tick de
  // uma instalação sem nenhuma solicitação vencida — que é o caso normal.
  if (alarmedCount > 0 || dedupedCount > 0 || errorsCount > 0) {
    void audit({
      action: "lgpd.sla_watcher_run",
      requestId,
      bypassedRls: true,
      metadata: {
        scanned,
        alarmed: alarmedCount,
        deduped: dedupedCount,
        errors: errorsCount,
        duration_ms: durationMs,
      },
    });
  }

  return ok(
    { scanned, alarmed: alarmedCount, deduped: dedupedCount, errors: errorsCount },
    { requestId },
  );
}

