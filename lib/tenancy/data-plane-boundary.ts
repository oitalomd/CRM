import type { SupabaseClient } from "@supabase/supabase-js";
import type { Pool } from "pg";

import { getOrganizationDataPlanePool } from "./data-plane-registry";

export type OrganizationDataPlane =
  | { mode: "shared"; organizationId: string; pool: null }
  | { mode: "dedicated"; organizationId: string; pool: Pool };

/**
 * Resolves the storage plane without silently falling back after provisioning
 * has started. An organization with no registry row is still on the legacy
 * shared plane; any explicit non-ready row is an operational error and must be
 * fixed before serving tenant data.
 */
export async function resolveOrganizationDataPlane(
  organizationId: string,
  admin?: SupabaseClient,
): Promise<OrganizationDataPlane> {
  try {
    return {
      mode: "dedicated",
      organizationId,
      pool: await getOrganizationDataPlanePool(organizationId, admin),
    };
  } catch (error) {
    if (error instanceof Error && error.message === "data_plane_not_registered") {
      return { mode: "shared", organizationId, pool: null };
    }
    throw error;
  }
}

