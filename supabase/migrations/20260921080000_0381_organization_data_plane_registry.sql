-- 0381 — registro do banco dedicado de cada organização
--
-- Esta tabela pertence ao control plane (Supabase atual). Ela não move dados
-- nem altera o caminho compartilhado existente; apenas registra a conexão que
-- será usada quando um tenant for migrado para o data plane dedicado.
--
-- A URI inteira fica cifrada no servidor com AI_CRED_AES_KEY. Nem host, usuário
-- ou senha devem aparecer em uma tabela acessível ao cliente. A tabela não tem
-- policies para usuários finais: somente o cliente admin do servidor pode ler
-- o registro, e esse cliente só é chamado depois de resolver o vínculo do
-- usuário com a organização.

create table if not exists public.organization_data_planes (
  organization_id uuid primary key
    references public.organizations(id) on delete cascade,
  status text not null default 'provisioning'
    check (status in ('provisioning', 'ready', 'degraded', 'retiring', 'failed')),
  connection_uri_encrypted bytea not null,
  connection_uri_iv bytea not null,
  connection_uri_tag bytea not null,
  connection_uri_last4 text not null
    check (char_length(connection_uri_last4) between 1 and 4),
  schema_version integer not null default 0
    check (schema_version >= 0),
  last_healthcheck_at timestamptz,
  last_migration_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organization_data_planes is
  'Control-plane registry for one dedicated PostgreSQL data plane per organization.';
comment on column public.organization_data_planes.connection_uri_encrypted is
  'AES-256-GCM ciphertext; plaintext must never be returned to a browser or logged.';

alter table public.organization_data_planes enable row level security;

-- Não criar policy para authenticated. O registry é um segredo operacional e
-- só pode ser lido pelo backend com service role depois da autorização própria.
revoke all on public.organization_data_planes from anon, authenticated;
grant select, insert, update, delete on public.organization_data_planes to service_role;

create index if not exists organization_data_planes_status_idx
  on public.organization_data_planes(status);

create or replace function public.touch_organization_data_plane_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists organization_data_planes_touch_updated_at
  on public.organization_data_planes;
create trigger organization_data_planes_touch_updated_at
before update on public.organization_data_planes
for each row execute function public.touch_organization_data_plane_updated_at();

