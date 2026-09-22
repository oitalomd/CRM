/**
 * O FLUXO PUBLICADO QUE NUNCA VAI DISPARAR.
 *
 * Um gatilho automático de follow-up (silêncio, etapa do funil, caso aberto,
 * falta a compromisso) só cria inscrição se algum agente PUBLICADO tem o
 * ponteiro em `followup.flow_pointer_ids` — `lib/followup/agent-followup-gate.ts`,
 * e a mesma condição escrita de novo em SQL dentro de `fn_appointment_recover`.
 *
 * Faltando esse vínculo, todo produtor sai por `pointers_armados = 0` **em
 * silêncio**. O fluxo aparece `active` na tela, com versão publicada e gatilho
 * configurado, e nenhum contato é reengajado: sem erro, sem log que alguém leia,
 * sem linha em tabela nenhuma. Quem publicou acha que ligou o follow-up, e a
 * descoberta acontece semanas depois — quando alguém pergunta por que ninguém
 * recebeu mensagem.
 *
 * É o invariante 6 do Sistema Vivo: o `return` mudo em cima de estado
 * configurável. E ficou mais fácil de cair depois da galeria de modelos
 * (`lib/followup/modelos/`), que instala um fluxo em dois cliques sem passar
 * pela tela do agente — a galeria AVISA que falta esse passo, mas aviso que
 * aparece uma vez, na hora de instalar, não alcança quem fechou a aba.
 *
 * ═══ POR QUE ELE TAMBÉM FECHA O AVISO ═══
 *
 * Esta rodada RECONCILIA, não só denuncia: fluxo desarmado abre aviso, fluxo que
 * ganhou agente FECHA o que estava aberto. Sem a segunda metade, quem consertasse
 * ficaria com um aviso permanente pedindo algo já feito — e aviso que não some
 * quando o problema some é a maneira mais rápida de ensinar a equipe a ignorar a
 * Central. É o laço do invariante 7: o que abriu tem quem feche.
 *
 * Por isso não há teto de insistência como no `case-stale-watcher`: ali cada
 * cobrança é uma mensagem nova sobre o mesmo caso; aqui é UM aviso por fluxo,
 * que fica aberto enquanto o defeito durar e some sozinho quando ele acabar.
 *
 * ═══ O QUE ELE NÃO OLHA ═══
 *
 * `manual` e `webhook` ficam de fora — funcionam sem agente nenhum
 * (`lib/followup/enroll.ts` segue com `agent_id = null`). Avisar sobre eles
 * seria alarme falso. A lista é `GATILHOS_QUE_EXIGEM_AGENTE`, ao lado do gate.
 */
import { randomUUID } from "node:crypto";
import type { NextRequest } from "next/server";

import { ok, fail } from "@/lib/api/wrappers";
import { audit } from "@/lib/audit";
import { env } from "@/lib/env";
import { logger } from "@/lib/logger";
import { createAdminClient } from "@/lib/supabase/admin";
import {
  createSupabaseFollowupGateDb,
  exigeAgente,
  type FollowupGateDb,
} from "@/lib/followup/agent-followup-gate";
import { getTenantDataClient } from "@/lib/tenancy/data-plane-registry";

export const dynamic = "force-dynamic";

/** Teto por rodada. Roda de hora em hora; o que sobrar volta na seguinte. */
const LIMITE_DA_VARREDURA = 500;

const KIND = "followup_sem_agente";

/** O gatilho em português — o aviso não mostra `stage_change` a ninguém. */
const COMO_DISPARA: Record<string, string> = {
  silence: "depois de um tempo sem o contato responder",
  stage_change: "quando um negócio entra numa etapa do funil",
  case_opened: "quando um atendimento é aberto",
  appointment_no_show: "quando alguém confirma que o contato não compareceu",
};

interface PonteiroDesarmado {
  id: string;
  organization_id: string;
  name: string;
  kind: string;
}

export function corpoDoAviso(nome: string, kind: string): string {
  const quando = COMO_DISPARA[kind] ?? "pelo gatilho configurado";
  return (
    `O fluxo «${nome}» está publicado e dispararia ${quando} — mas nenhum agente publicado ` +
    `arma ele, e por isso nenhum contato entra. Abra IA › Agentes, escolha o agente que ` +
    `atende esse número, marque «${nome}» em "follow-ups que arma" e publique a versão. ` +
    `Este aviso se resolve sozinho quando o vínculo existir.`
  );
}

async function handle(req: NextRequest): Promise<Response> {
  const requestId = randomUUID();

  const auth = req.headers.get("authorization") ?? "";
  const fornecido = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length).trim() : "";
  const aceitos = [env.INTERNAL_CRON_SECRET, env.INTERNAL_SECRET].filter(Boolean);
  if (aceitos.length === 0 || !fornecido || !aceitos.includes(fornecido)) {
    return fail("forbidden", "Cron secret missing or invalid.", 403, { requestId });
  }

  const admin = createAdminClient();

  const { data: organizations, error: organizationsError } = await admin
    .from("organizations")
    .select("id")
    .limit(LIMITE_DA_VARREDURA);
  if (organizationsError) {
    logger.error("[followup-sem-agente] falha ao listar organizações", {
      error: organizationsError.message,
      requestId,
    });
    return fail("internal_error", "Falha ao buscar organizações.", 500, { requestId });
  }

  const dataClientByOrg = new Map<string, ReturnType<typeof createAdminClient>>();
  const rows: Array<Record<string, unknown>> = [];
  for (const organization of organizations ?? []) {
    try {
      const dataClient = await getTenantDataClient(organization.id, admin);
      dataClientByOrg.set(organization.id, dataClient);
      const { data, error } = await dataClient
        .from("followup_flow_pointers")
        .select("id, organization_id, name, trigger_config")
        .eq("organization_id", organization.id)
        .eq("status", "active")
        .limit(LIMITE_DA_VARREDURA);
      if (error) {
        logger.error("[followup-sem-agente] consulta por organização falhou", {
          organizationId: organization.id,
          error: error.message,
          requestId,
        });
        continue;
      }
      rows.push(...((data ?? []) as Array<Record<string, unknown>>));
    } catch (err) {
      logger.warn("[followup-sem-agente] data plane indisponível; organização ignorada", {
        organizationId: organization.id,
        error: err instanceof Error ? err.message : String(err),
        requestId,
      });
    }
  }

  // O recorte por kind acontece AQUI, e não no PostgREST, para o vocabulário
  // viver num lugar só (`GATILHOS_QUE_EXIGEM_AGENTE`). Uma lista repetida num
  // filtro `trigger_config->>kind=in.(...)` divergiria no primeiro gatilho novo.
  const candidatos: PonteiroDesarmado[] = rows.flatMap((linha) => {
    const cfg = linha.trigger_config as { kind?: unknown } | null;
    const kind = typeof cfg?.kind === "string" ? cfg.kind : "manual";
    return exigeAgente(kind)
      ? [{
          id: linha.id as string,
          organization_id: linha.organization_id as string,
          name: linha.name as string,
          kind,
        }]
      : [];
  });

  // Uma leitura de agentes por ORGANIZAÇÃO, não por fluxo: `loadEnabled…` varre
  // as versões publicadas da org inteira, e uma clínica com quatro modelos
  // instalados pagaria a mesma varredura quatro vezes por rodada.
  const armadosPorOrg = new Map<string, Set<string>>();
  for (const orgId of new Set(candidatos.map((c) => c.organization_id))) {
    try {
      const dataClient = dataClientByOrg.get(orgId);
      if (!dataClient) continue;
      const gateDb: FollowupGateDb = createSupabaseFollowupGateDb(dataClient);
      const agentes = await gateDb.loadEnabledPublishedFollowupAgents(orgId);
      armadosPorOrg.set(orgId, new Set(agentes.flatMap((a) => a.pointerIds)));
    } catch (err) {
      // Organização que falhou não vira "desarmada": sem a leitura dos agentes
      // não se sabe nada, e abrir aviso no escuro é pior que não avisar.
      logger.error("[followup-sem-agente] agentes da organização não puderam ser lidos", {
        organization_id: orgId,
        error: err instanceof Error ? err.message : String(err),
        requestId,
      });
    }
  }

  let abertos = 0;
  let jaAbertos = 0;
  let fechados = 0;

  for (const ponteiro of candidatos) {
    const armados = armadosPorOrg.get(ponteiro.organization_id);
    if (!armados) continue; // leitura de agentes falhou; tenta na rodada seguinte
    const dataClient = dataClientByOrg.get(ponteiro.organization_id);
    if (!dataClient) continue;

    const { data: avisoAberto } = await dataClient
      .from("agent_inbox_items")
      .select("id")
      .eq("organization_id", ponteiro.organization_id)
      .eq("kind", KIND)
      .eq("ref_id", ponteiro.id)
      .eq("status", "open")
      .maybeSingle();

    if (armados.has(ponteiro.id)) {
      // O vínculo apareceu: o aviso perdeu o assunto e é fechado por quem o abriu.
      if (!avisoAberto) continue;
      const { error: erroFechar } = await dataClient
        .from("agent_inbox_items")
        .update({ status: "resolved" })
        .eq("id", avisoAberto.id)
        .eq("organization_id", ponteiro.organization_id);
      if (erroFechar) {
        logger.error("[followup-sem-agente] aviso não pôde ser fechado", {
          pointer_id: ponteiro.id,
          error: erroFechar.message,
          requestId,
        });
        continue;
      }
      fechados += 1;
      continue;
    }

    if (avisoAberto) {
      jaAbertos += 1;
      continue;
    }

    const { error: erroAviso } = await dataClient.from("agent_inbox_items").insert({
      organization_id: ponteiro.organization_id,
      kind: KIND,
      // `warn` e não `critical`: nada está fora do ar, e o vermelho é para o que
      // está. Mas também não é `info` — há gente que devia estar sendo
      // reengajada e não está, e isso pede uma ação de alguém.
      severity: "warn",
      title: `O follow-up «${ponteiro.name}» não está disparando`,
      body: corpoDoAviso(ponteiro.name, ponteiro.kind),
      ref_kind: "followup_flow",
      ref_id: ponteiro.id,
    });

    if (erroAviso) {
      logger.error("[followup-sem-agente] aviso não foi aberto", {
        pointer_id: ponteiro.id,
        organization_id: ponteiro.organization_id,
        error: erroAviso.message,
        requestId,
      });
      continue;
    }
    abertos += 1;
  }

  // Rodada que não mexeu em nada NÃO é mutação e não audita (CLAUDE.md §Audit
  // log, vigiado por `cron-audita-so-quando-ha-efeito.test.ts`). Fechar aviso É
  // efeito: alguém consertou, e o histórico tem de registrar que o sistema viu.
  if (abertos > 0 || fechados > 0) {
    await audit({
      action: "ai.followup_sem_agente_reconciliado",
      resourceType: "followup_flow_pointer",
      requestId,
      metadata: { abertos, fechados, examinados: candidatos.length },
    });
  }

  return ok(
    { examinados: candidatos.length, abertos, fechados, ja_abertos: jaAbertos },
    { requestId },
  );
}

export const GET = handle;
export const POST = handle;

