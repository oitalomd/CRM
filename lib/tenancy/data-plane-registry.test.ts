import { describe, expect, it } from "vitest";

import { getOrganizationDataPlanePool } from "./data-plane-registry";

function adminReturning(row: unknown, error: { message: string } | null = null) {
  return {
    from() {
      return {
        select() {
          return {
            eq() {
              return { maybeSingle: async () => ({ data: row, error }) };
            },
          };
        },
      };
    },
  } as never;
}

describe("data-plane registry", () => {
  it("falha fechado quando a organização não tem banco registrado", async () => {
    await expect(
      getOrganizationDataPlanePool("org-sem-banco", adminReturning(null)),
    ).rejects.toThrow("data_plane_not_registered");
  });

  it("não abre conexão enquanto o provisionamento não está pronto", async () => {
    await expect(
      getOrganizationDataPlanePool(
        "org-provisionando",
        adminReturning({
          organization_id: "org-provisionando",
          status: "provisioning",
          schema_version: 0,
          connection_uri_encrypted: "",
          connection_uri_iv: "",
          connection_uri_tag: "",
        }),
      ),
    ).rejects.toThrow("data_plane_not_ready:provisioning");
  });

  it("propaga falha de leitura do control plane", async () => {
    await expect(
      getOrganizationDataPlanePool(
        "org-com-erro",
        adminReturning(null, { message: "permission denied" }),
      ),
    ).rejects.toThrow("data_plane_registry_read_failed: permission denied");
  });
});

