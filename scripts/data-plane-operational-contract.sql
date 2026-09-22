-- Contrato mínimo do data plane PostgreSQL do DeskcommCRM.
--
-- Este arquivo não cria login, sessão, OAuth ou Storage. O control plane
-- Supabase continua sendo a autoridade para isso. O objetivo é deixar
-- explícito, no próprio banco operacional, qual contrato foi instalado antes
-- de ele poder receber tráfego.

create table if not exists public.deskcomm_operational_contract (
  singleton boolean primary key default true check (singleton),
  contract_version integer not null check (contract_version > 0),
  identity_source text not null check (identity_source = 'supabase-cloud'),
  storage_source text not null check (storage_source = 'supabase-cloud'),
  installed_at timestamptz not null default now()
);

insert into public.deskcomm_operational_contract
  (singleton, contract_version, identity_source, storage_source)
values
  (true, 1, 'supabase-cloud', 'supabase-cloud')
on conflict (singleton) do update set
  contract_version = excluded.contract_version,
  identity_source = excluded.identity_source,
  storage_source = excluded.storage_source;

comment on table public.deskcomm_operational_contract is
  'Declares that this PostgreSQL data plane receives identity and storage references from the Supabase Cloud control plane.';

