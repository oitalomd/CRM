import { describe, expect, it, vi } from "vitest";

import { syncOrganizationDataPlaneIdentities } from "./data-plane-identity";

describe("data-plane identity mirror", () => {
  it("replica somente membros da organização e não copia credenciais", async () => {
    const query = vi.fn().mockResolvedValue({ rows: [], rowCount: 1 });
    const controlPlane = {
      from: () => ({
        select: () => ({
          eq: async () => ({ data: [{ user_id: "user-a" }, { user_id: "user-b" }], error: null }),
        }),
      }),
      auth: {
        admin: {
          listUsers: async () => ({
            data: {
              users: [
                { id: "user-a", email: "a@example.test", user_metadata: { full_name: "A" } },
                { id: "user-b", email: "b@example.test", user_metadata: { full_name: "B" } },
                { id: "other", email: "other@example.test", user_metadata: { full_name: "Other" } },
              ],
            },
            error: null,
          }),
        },
      },
    } as never;

    await expect(syncOrganizationDataPlaneIdentities({
      organizationId: "org-a",
      pool: { query },
      controlPlane,
    })).resolves.toEqual({ synced: 2 });
    expect(query).toHaveBeenCalledTimes(2);
    expect(query.mock.calls[0]?.[0]).toContain("raw_user_meta_data");
    expect(query.mock.calls[0]?.[0]).not.toMatch(/password|refresh_token|encrypted/i);
  });
});

