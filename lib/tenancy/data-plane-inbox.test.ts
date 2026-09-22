import { describe, expect, it, vi } from "vitest";

import { listDedicatedConversations } from "./data-plane-inbox";

describe("dedicated inbox query", () => {
  it("fixa o organization_id no SQL e parametriza filtros", async () => {
    const query = vi.fn().mockResolvedValue({
      rows: [
        {
          id: "conversation-a",
          organization_id: "org-a",
          contact_id: "contact-a",
          channel: "whatsapp",
          status: "open",
          last_inbound_at: "2026-09-21T12:00:00.000Z",
          last_message_at: "2026-09-21T12:00:00.000Z",
          last_message_preview: "hello",
          unread_count_for_assignee: 1,
          created_at: "2026-09-21T11:00:00.000Z",
          organization_display_name: "Org A",
          organization_slug: "org-a",
          contact_name: "Contact A",
          contact_phone_number: "+5511999999999",
        },
      ],
    });

    const rows = await listDedicatedConversations({
      pool: { query } as never,
      tenantId: "org-a",
      status: "open",
      q: "hello",
      cursorPayload: null,
      limit: 30,
    });

    expect(query).toHaveBeenCalledOnce();
    const [sql, values] = query.mock.calls[0] as [string, unknown[]];
    expect(sql).toContain("c.organization_id = $1");
    expect(sql).not.toContain("org-a");
    expect(values).toEqual(["org-a", "open", "%hello%", 31]);
    expect(rows[0]?.organizations).toEqual({ display_name: "Org A", slug: "org-a" });
  });

  it("não permite que o cursor remova o filtro do tenant", async () => {
    const query = vi.fn().mockResolvedValue({ rows: [] });

    await listDedicatedConversations({
      pool: { query } as never,
      tenantId: "org-b",
      cursorPayload: { last_inbound_at: null, id: "conversation-b" },
      limit: 10,
    });

    const [sql, values] = query.mock.calls[0] as [string, unknown[]];
    expect(sql).toContain("c.organization_id = $1");
    expect(sql).toContain("c.last_inbound_at is null");
    expect(values).toEqual(["org-b", 11]);
  });
});

