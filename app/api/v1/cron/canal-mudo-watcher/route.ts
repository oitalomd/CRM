/**
 * canal-mudo-watcher — o canal que nasce mudo não fica mudo em silêncio.
 *
 * Decisão do dono (doc 11, opção B): o canal de WhatsApp continua nascendo em
 * modo de teste, que é o certo — ninguém recebe resposta automática por
 * acidente durante a configuração —, e o SISTEMA passa a não deixar esquecer.
 *
 * O esquecimento é o defeito inteiro, e o sintoma é o pior possível: as
 * mensagens CHEGAM no Inbox, tudo parece funcionar, e a IA nunca responde. Quem
 * instalou conclui que o produto está quebrado, não que falta um clique. A tela
 * de Conexões já diz "Nenhum número autorizado — a IA não responde ninguém
 * neste canal"; este cron alcança quem não abre Conexões.
 *
 * ── Por que um cron próprio, diário ─────────────────────────────────────────
 *
 * O `channel-health` roda de 5 em 5 minutos e faz uma chamada de REDE por
 * sessão (teto de 50). Esta varredura não fala com ninguém: é leitura de banco,
 * e a régua dela é "alguns dias". Pendurá-la lá custaria 288 varreduras por dia
 * para um estado que muda em dias, e ficaria limitada pelo teto de rede alheio.
 *
 * ── O laço de retorno (DoD 13) ──────────────────────────────────────────────
 *
 * A MESMA rodada que abre o aviso o fecha quando ele deixa de ser verdade:
 * canal que ganhou número, saiu do modo de teste ou foi arquivado tem o aviso
 * resolvido com o motivo no corpo. Aviso que só some no clique de alguém vira
 * lista que ninguém lê — e, aqui, viraria mentira: o canal já responde.
 */
import { randomUUID } from "node:crypto";

import type { NextRequest } from "next/server";

import { ok, fail } from "@/lib/api/wrappers";
import { audit } from "@/lib/audit";
import {
  avaliarCanal,
  DIAS_ATE_AVISAR,
  KIND_CANAL_MUDO,
  type CanalParaAvaliar,
  type MotivoDaResolucao,
} from "@/lib/channels/canal-mudo";
import { env } from "@/lib/env";
import { logger } from "@/lib/logger";
import { createAdminClient } from "@/lib/supabase/admin";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";

export const dynamic = "force-dynamic";

/** Teto por rodada. Leitura de banco, sem rede — cabe folgado numa instalação real. */
const LIMITE = 500;

/** O que o corpo do aviso diz a quem abre a Central. Sem jargão e com a saída. */
const CORPO_DO_AVISO =
  "Este canal está em modo de teste e não tem nenhum número autorizado, " +
  "então a IA não responde a ninguém nele — as mensagens chegam no Inbox e " +
  "ficam sem resposta automática. Em Conexões, autorize os números de teste " +
  "ou abra o canal ao público.";

const MOTIVO_LEGIVEL: Record<MotivoDaResolucao, string> = {
  ganhou_numero: "o canal ganhou número autorizado",
  saiu_do_modo_de_teste: "o canal saiu do modo de teste",
  canal_arquivado: "o canal foi arquivado",
};

interface AvisoAberto {
  id: string;
  ref_id: string | null;
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
  const agora = new Date();

  const { data: organizations, error: organizationsError } = await admin
    .from("organizations")
    .select("id");
  if (organizationsError) {
    logger.error("[canal-mudo-watcher] falha ao listar organizações", {
      detail: organizationsError.message,
      requestId,
    });
    return fail("internal_error", organizationsError.message, 500, { requestId });
  }

  let avisados = 0;
  let resolvidos = 0;
  let canaisExaminados = 0;

  for (const organization of organizations ?? []) {
    let dataClient: ReturnType<typeof createAdminClient>;
    try {
      dataClient = await getTenantDataClient(organization.id, admin);
    } catch (err) {
      logger.warn("[canal-mudo-watcher] data plane indisponível; organização ignorada", {
        organizationId: organization.id,
        error: err instanceof Error ? err.message : String(err),
        requestId,
      });
      continue;
    }

    // Os avisos abertos vêm antes das conexões: eles também cobrem canal que
    // sumiu da varredura por ter sido arquivado.
    const { data: abertosBruto, error: erroAvisos } = await dataClient
      .from("agent_inbox_items")
      .select("id, ref_id")
      .eq("organization_id", organization.id)
      .eq("kind", KIND_CANAL_MUDO)
      .eq("status", "open")
      .limit(LIMITE);
    if (erroAvisos) {
      logger.error("[canal-mudo-watcher] leitura dos avisos falhou", {
        organizationId: organization.id,
        detail: erroAvisos.message,
        requestId,
      });
      continue;
    }
    const abertos = new Map<string, AvisoAberto>();
    for (const a of (abertosBruto ?? []) as AvisoAberto[]) {
      if (a.ref_id !== null) abertos.set(a.ref_id, a);
    }

    const { data: canaisBruto, error: erroCanais } = await dataClient
      .from("channel_sessions")
      .select("id, organization_id, status, archived_at, last_status_change_at, metadata")
      .eq("organization_id", organization.id)
      .is("archived_at", null)
      .limit(LIMITE);
    if (erroCanais) {
      logger.error("[canal-mudo-watcher] leitura das conexões falhou", {
        organizationId: organization.id,
        detail: erroCanais.message,
        requestId,
      });
      continue;
    }

    const canais = (canaisBruto ?? []) as CanalParaAvaliar[];
    canaisExaminados += canais.length;
    const resolver = async (aviso: AvisoAberto, motivo: MotivoDaResolucao): Promise<void> => {
      const { data } = await dataClient
        .from("agent_inbox_items")
        .update({
          status: "resolved",
          body: `${CORPO_DO_AVISO}\n\nResolvido pelo sistema: ${MOTIVO_LEGIVEL[motivo]}.`,
        })
        .eq("id", aviso.id)
        .eq("organization_id", organization.id)
        .eq("status", "open")
        .select("id")
        .maybeSingle();
      if (data) resolvidos++;
    };

    for (const canal of canais) {
      const desfecho = avaliarCanal(canal, agora);
      const aberto = abertos.get(canal.id);
      abertos.delete(canal.id);
      if (desfecho.acao === "resolver") {
        if (aberto) await resolver(aberto, desfecho.motivo);
        continue;
      }
      if (desfecho.acao === "aguardar" || aberto) continue;

      const { data } = await dataClient
        .from("agent_inbox_items")
        .insert({
          organization_id: organization.id,
          kind: KIND_CANAL_MUDO,
          severity: "warn",
          title: "Este canal está em modo de teste — a IA não responde ninguém",
          body: `${CORPO_DO_AVISO}\n\nAssim há ${desfecho.diasMudo} dia(s).`,
          ref_kind: "channel_session",
          ref_id: canal.id,
        })
        .select("id")
        .maybeSingle();
      if (data) avisados++;
    }

    // O que sobrou é aviso de canal arquivado ou apagado.
    for (const aviso of abertos.values()) await resolver(aviso, "canal_arquivado");
  }

  // Rodada que não abriu nem fechou nada NÃO é mutação e não ocupa linha na
  // auditoria: 365 batidas por ano numa instalação que configurou tudo no
  // primeiro dia seriam 365 linhas dizendo que nada aconteceu.
  if (avisados > 0 || resolvidos > 0) {
    void audit({
      action: "channel.canal_mudo_watcher_run",
      organizationId: null,
      bypassedRls: true,
      metadata: { canais: canaisExaminados, avisados, resolvidos, diasAteAvisar: DIAS_ATE_AVISAR },
      requestId,
    });
  }

  return ok({ canais: canaisExaminados, avisados, resolvidos }, { requestId });
}

export async function GET(req: NextRequest): Promise<Response> {
  return handle(req);
}

export async function POST(req: NextRequest): Promise<Response> {
  return handle(req);
}

