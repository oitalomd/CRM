/**
 * Fetch adapter for Supabase's new `sb_secret_...` keys.
 *
 * New-format keys are API keys, not JWTs. Supabase requires them in `apikey`
 * and rejects them when an SDK fallback also sends them as Bearer tokens.
 */
export function supabaseAdminFetch(apiKey: string): typeof fetch {
  const isNewSecret = apiKey.startsWith("sb_secret_");
  if (!isNewSecret) return fetch;

  return async (input, init) => {
    const headers = new Headers(init?.headers);
    headers.set("apikey", apiKey);
    headers.delete("authorization");
    headers.delete("Authorization");
    return fetch(input, { ...init, headers });
  };
}

