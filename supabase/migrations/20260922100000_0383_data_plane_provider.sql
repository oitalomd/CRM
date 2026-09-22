-- 0383 — explicita o contrato do data plane registrado no control plane.
-- O default preserva registros existentes como Supabase-compatible. PostgreSQL
-- vanilla só pode ser promovido pelo gate depois do baseline operacional.
alter table public.organization_data_planes
  add column if not exists data_plane_provider text not null default 'supabase';

alter table public.organization_data_planes
  drop constraint if exists organization_data_planes_data_plane_provider_check;

alter table public.organization_data_planes
  add constraint organization_data_planes_data_plane_provider_check
  check (data_plane_provider in ('supabase', 'postgresql'));

comment on column public.organization_data_planes.data_plane_provider is
  'Protocol and schema contract used by the dedicated plane; postgresql is promoted only after its operational baseline is installed.';

