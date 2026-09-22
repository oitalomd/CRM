import type { Pool } from "pg";
import type { SupabaseClient } from "@supabase/supabase-js";

type OrganizationMember = { user_id: string };

/**
 * Mirrors only the identities referenced by one organization into its
 * operational PostgreSQL database. Auth remains exclusively in Supabase
 * Cloud; no password, refresh token or session secret is copied.
 */
export async function syncOrganizationDataPlaneIdentities(input: {
  organizationId: string;
  pool: Pick<Pool, "query">;
  controlPlane: SupabaseClient;
}): Promise<{ synced: number }> {
  const membership = await input.controlPlane
    .from("user_organizations")
    .select("user_id")
    .eq("organization_id", input.organizationId);
  if (membership.error) {
    throw new Error(`data_plane_identity_members_read_failed:${membership.error.message}`);
  }

  const ids = new Set(
    ((membership.data ?? []) as OrganizationMember[])
      .map((row) => row.user_id)
      .filter((id): id is string => typeof id === "string" && id.length > 0),
  );
  if (ids.size === 0) return { synced: 0 };

  const users = new Map<string, { email: string | null; metadata: Record<string, unknown> }>();
  for (let page = 1; ; page += 1) {
    const listed = await input.controlPlane.auth.admin.listUsers({ page, perPage: 1000 });
    if (listed.error) {
      throw new Error(`data_plane_identity_users_read_failed:${listed.error.message}`);
    }
    for (const user of listed.data.users) {
      if (ids.has(user.id)) {
        users.set(user.id, {
          email: user.email ?? null,
          metadata: user.user_metadata ?? {},
        });
      }
    }
    if (listed.data.users.length < 1000) break;
  }

  for (const userId of ids) {
    const user = users.get(userId);
    if (!user) throw new Error(`data_plane_identity_user_missing:${userId}`);
    await input.pool.query(
      `insert into auth.users (id, email, raw_user_meta_data)
       values ($1, $2, $3::jsonb)
       on conflict (id) do update set
         email = excluded.email,
         raw_user_meta_data = excluded.raw_user_meta_data`,
      [userId, user.email, JSON.stringify(user.metadata)],
    );
  }

  return { synced: ids.size };
}

