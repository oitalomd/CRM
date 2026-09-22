import { describe, expect, it, vi } from "vitest";

import { getOrganizationDataPlanePool } from "./data-plane-registry";
import { resolveOrganizationDataPlane } from "./data-plane-boundary";

vi.mock("./data-plane-registry", () => ({
  getOrganizationDataPlanePool: vi.fn(),
}));

const getPool = vi.mocked(getOrganizationDataPlanePool);

describe("organization data-plane boundary", () => {
  it("mantém organizações sem registro no plano compartilhado", async () => {
    getPool.mockRejectedValueOnce(new Error("data_plane_not_registered"));

    await expect(resolveOrganizationDataPlane("org-shared")).resolves.toEqual({
      mode: "shared",
      organizationId: "org-shared",
      pool: null,
    });
  });

  it("não faz fallback quando o tenant já iniciou migração", async () => {
    getPool.mockRejectedValueOnce(new Error("data_plane_not_ready:provisioning"));

    await expect(resolveOrganizationDataPlane("org-provisioning")).rejects.toThrow(
      "data_plane_not_ready:provisioning",
    );
  });
});

