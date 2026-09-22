-- selfhost-prelude.sql — ponte de compatibilidade do data plane operacional
-- PostgreSQL (sem serviço Supabase): roles, identidade espelhada, metadata de
-- Storage e extensões que o baseline operacional supõe.
-- (uuid-ossp, pgcrypto, vector, citext, pg_trgm).
--
-- QUANDO USAR: só no caminho "Postgres próprio" do self-host. Com um projeto
-- Supabase (o caminho recomendado do README), NADA disto é necessário — o
-- Supabase já fornece tudo nativo (e com Auth/Storage REAIS, não stubs).
-- O Supabase Cloud continua sendo a autoridade de login e Storage. Estas
-- tabelas não implementam login nem upload: preservam apenas FKs, auditoria e
-- funções SQL enquanto o servidor encaminha Auth/Storage para o control plane.
--
-- Fonte: o mesmo prelude do gate de CI (scripts/test-db.sh) — se editar um,
-- edite o outro.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

create schema if not exists auth;
create schema if not exists extensions;

-- O baseline referencia extensions.uuid_generate_v4/gen_random_bytes e os tipos
-- public.vector/public.citext + gin_trgm_ops, mas não cria as extensões (pg_dump).
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists vector with schema public;
create extension if not exists citext with schema public;
create extension if not exists pg_trgm with schema public;

-- Stubs de storage (o apêndice do baseline cria buckets + policies em storage.objects).
create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz not null default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz not null default now()
);

-- Stub de auth.users (FKs do baseline apontam pra cá).
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Contrato usado por funções de suporte: a sessão continua pertencendo ao Auth
-- Cloud; o data plane só mantém a réplica mínima necessária para validações.
create table if not exists auth.sessions (
  id uuid primary key,
  user_id uuid not null references auth.users(id),
  aal text,
  not_after timestamptz
);
create table if not exists auth.mfa_factors (
  id uuid primary key,
  user_id uuid not null references auth.users(id),
  status text,
  factor_type text default 'totp'
);

create or replace function auth.jwt() returns jsonb
  language sql stable
  as $$
    select coalesce(
      nullif(current_setting('request.jwt.claim', true), ''),
      nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb;
  $$;

-- Stub de auth.uid() lendo o claim `sub` de request.jwt.claims (mesmo contrato
-- do Supabase; os testes simulam o JWT via set_config).
create or replace function auth.uid() returns uuid
  language sql stable
  as $fn$
    select coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  $fn$;

grant usage on schema auth, extensions, storage to anon, authenticated, service_role;
grant select on auth.users to anon, authenticated, service_role;

-- Promotion gate: a PostgreSQL data plane is not accepted until this contract
-- is installed alongside the operational baseline.
create table if not exists public.deskcomm_operational_contract (
  singleton boolean primary key default true check (singleton),
  contract_version integer not null check (contract_version > 0),
  identity_source text not null check (identity_source = 'supabase-cloud'),
  storage_source text not null check (storage_source = 'supabase-cloud'),
  installed_at timestamptz not null default now()
);
insert into public.deskcomm_operational_contract
  (singleton, contract_version, identity_source, storage_source)
values (true, 1, 'supabase-cloud', 'supabase-cloud')
on conflict (singleton) do update set
  contract_version = excluded.contract_version,
  identity_source = excluded.identity_source,
  storage_source = excluded.storage_source;

