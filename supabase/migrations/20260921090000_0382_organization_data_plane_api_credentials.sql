-- 0382 — API credentials for a Supabase-compatible dedicated data plane.
-- Values are encrypted with the same server-side AES key as other credentials.
alter table public.organization_data_planes
  add column if not exists api_url_encrypted bytea,
  add column if not exists api_url_iv bytea,
  add column if not exists api_url_tag bytea,
  add column if not exists api_key_encrypted bytea,
  add column if not exists api_key_iv bytea,
  add column if not exists api_key_tag bytea;

comment on column public.organization_data_planes.api_url_encrypted is
  'Encrypted Supabase project URL used for PostgREST data-plane access.';
comment on column public.organization_data_planes.api_key_encrypted is
  'Encrypted Supabase service/secret key; never returned to clients or logs.';

