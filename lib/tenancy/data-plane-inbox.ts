import type { Pool } from "pg";

export interface ConversationCursor {
  last_inbound_at: string | null;
  id: string;
}

export async function listDedicatedConversations(input: {
  pool: Pool;
  tenantId: string;
  q?: string;
  status?: "pending" | "open" | "resolved";
  cursorPayload: ConversationCursor | null;
  limit: number;
}) {
  const params: unknown[] = [input.tenantId];
  const filters = ["c.organization_id = $1"];
  const add = (value: unknown) => {
    params.push(value);
    return `$${params.length}`;
  };

  if (input.status) filters.push(`c.status = ${add(input.status)}`);
  if (input.q) filters.push(`c.last_message_preview ilike ${add(`%${input.q}%`)}`);
  if (input.cursorPayload?.last_inbound_at) {
    const timestamp = add(input.cursorPayload.last_inbound_at);
    const id = add(input.cursorPayload.id);
    filters.push(
      `(c.last_inbound_at < ${timestamp} or (c.last_inbound_at = ${timestamp} and c.id < ${id}))`,
    );
  } else if (input.cursorPayload) {
    filters.push("c.last_inbound_at is null");
  }

  params.push(input.limit + 1);
  const result = await input.pool.query<Record<string, unknown>>(
    `select
       c.id, c.organization_id, c.contact_id, c.channel, c.status,
       c.last_inbound_at, c.last_message_at, c.last_message_preview,
       c.unread_count_for_assignee, c.created_at,
       o.display_name as organization_display_name, o.slug as organization_slug,
       ct.name as contact_name, ct.phone_number as contact_phone_number
     from public.conversations c
     join public.organizations o on o.id = c.organization_id
     left join public.contacts ct on ct.id = c.contact_id
     where ${filters.join(" and ")}
     order by c.last_inbound_at desc nulls last, c.id desc
     limit $${params.length}`,
    params,
  );

  return result.rows.map((row) => ({
    id: row.id,
    organization_id: row.organization_id,
    contact_id: row.contact_id,
    channel: row.channel,
    status: row.status,
    last_inbound_at: row.last_inbound_at,
    last_message_at: row.last_message_at,
    last_message_preview: row.last_message_preview,
    unread_count_for_assignee: row.unread_count_for_assignee,
    created_at: row.created_at,
    organizations: {
      display_name: row.organization_display_name,
      slug: row.organization_slug,
    },
    contacts: row.contact_id
      ? { name: row.contact_name, phone_number: row.contact_phone_number }
      : null,
  }));
}

