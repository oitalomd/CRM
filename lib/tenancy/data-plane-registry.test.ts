import { afterEach, describe, expect, it, vi } from "vitest";

import { getOrganizationDataPlanePool, getTenantDataClient } from "./data-plane-registry";

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
  afterEach(() => vi.unstubAllEnvs());

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

  it("mantém o cliente compartilhado somente quando não há registro", async () => {
    const shared = adminReturning(null);
    await expect(getTenantDataClient("org-sem-banco", shared)).resolves.toBe(shared);
  });

  it("bloqueia o fallback compartilhado no gate final do rollout", async () => {
    vi.stubEnv("TENANCY_REQUIRE_DEDICATED", "true");
    await expect(getTenantDataClient("org-sem-banco", adminReturning(null))).rejects.toThrow(
      "data_plane_required",
    );
  });

  it("não cria cliente Supabase com credenciais ausentes", async () => {
    await expect(
      getTenantDataClient(
        "org-sem-api",
        adminReturning({
          organization_id: "org-sem-api",
          status: "ready",
          schema_version: 381,
          connection_uri_encrypted: "x",
          connection_uri_iv: "x",
          connection_uri_tag: "x",
        }),
      ),
    ).rejects.toThrow("data_plane_api_credentials_missing");
  });
});

