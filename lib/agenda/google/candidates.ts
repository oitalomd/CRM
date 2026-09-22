import type { SupabaseClient } from "@supabase/supabase-js";
/** Seleção comum do cron e da prova PostgREST; associação antiga também é relida. */
export function googlePushCandidates(db: SupabaseClient, organizationId?: string, now = new Date()) {
  let query = db
    .from("calendar_google_reconcilable_appointments")
    .select("id,organization_id,user_id:owner_user_id")
    .or(
      "needs_google_push.eq.true,and(google_event_id.not.is.null,google_conflict.is.null),google_conflict->resolution.not.is.null",
    )
    .lte("google_next_attempt_at", now.toISOString())
    .not("owner_user_id", "is", null);
  if (organizationId) query = query.eq("organization_id", organizationId);
  return query.order("google_next_attempt_at").limit(50);
}

