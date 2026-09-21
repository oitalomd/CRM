Warning: truncated output (original token count: 421485)
... 637361 bytes omitted ...




SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'DeskcommCRM v0.1 - Migration 0001 platform_base applied 2026-04-28';



CREATE OR REPLACE FUNCTION "public"."activate_kb_version"("p_agent_id" "uuid", "p_version_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_org uuid;
  v_version_org uuid;
begin
  select organization_id into v_org from public.ai_agents where id = p_agent_id;
  if v_org is null then
    raise exception 'agent_not_found' using errcode = 'P0002';
  end if;

  select organization_id into v_version_org
    from public.ai_knowledge_versions
   where id = p_version_id and agent_id = p_agent_id;
  if v_version_org is null or v_version_org <> v_org then
    raise exception 'kb_version_not_found_or_cross_tenant' using errcode = '42501';
  end if;

  update public.ai_knowledge_versions
     set is_active = false
   where agent_id = p_agent_id and id <> p_version_id and is_active = true;

  update public.ai_knowledge_versions
     set is_active = true,
         activated_at = coalesce(activated_at, now())
   where id = p_version_id;

  update public.ai_agents
     set active_kb_version_id = p_version_id,
         updated_at = now()
   where id = p_agent_id;
end$$;


ALTER FUNCTION "public"."activate_kb_version"("p_agent_id" "uuid", "p_version_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."activate_kb_version"("p_agent_id" "uuid", "p_version_id" "uuid") IS 'Atomically activate a knowledge_version for an agent. Validates tenant scope.';



CREATE OR REPLACE FUNCTION "public"."emit_event"("p_event_type" "text", "p_entity_kind" "text", "p_entity_id" "uuid", "p_payload" "jsonb" DEFAULT '{}'::"jsonb", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb", "p_organization_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_org_id uuid;
  v_event_id uuid;
begin
  v_org_id := p_organization_id;
  if v_org_id is null then
    -- Try to resolve from caller's first org (best-effort; trigger callers MUST pass it)
    select organization_id into v_org_id
      from public.user_organizations
      where user_id = auth.uid() and revoked_at is null
      limit 1;
  end if;
  if v_org_id is null then
    raise exception 'emit_event: organization_id obrigatorio';
  end if;

  insert into public.event_log
    (organization_id, event_type, entity_kind, entity_id, payload, metadata)
  values
    (v_org_id, p_event_type, p_entity_kind, p_entity_id,
     coalesce(p_payload, '{}'::jsonb),
     coalesce(p_metadata, '{}'::jsonb)
       || jsonb_build_object('emitted_at', extract(epoch from now())))
  returning id into v_event_id;

  return v_event_id;
end $$;


ALTER FUNCTION "public"."emit_event"("p_event_type" "text", "p_entity_kind" "text", "p_entity_id" "uuid", "p_payload" "jsonb", "p_metadata" "jsonb", "p_organization_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_audit_log_row"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_action text;
  v_org    uuid;
begin
  if tg_op = 'INSERT' then
    v_action := tg_table_name || '.created';
    v_org    := new.organization_id;
  elsif tg_op = 'UPDATE' then
    v_action := tg_table_name || '.updated';
    v_org    := new.organization_id;
  elsif tg_op = 'DELETE' then
    v_action := tg_table_name || '.deleted';
    v_org    := old.organization_id;
  end if;

  insert into public.api_audit_log (organization_id, actor_user_id, action, resource_type, resource_id, metadata)
  values (
    v_org,
    auth.uid(),
    v_action,
    tg_table_name,
    coalesce(new.id, old.id),
    case when tg_op = 'UPDATE'
      then jsonb_build_object('changed_fields', '[diff suppressed in v0.1]')
      else '{}'::jsonb
    end
  );

  return coalesce(new, old);
end$$;


ALTER FUNCTION "public"."fn_audit_log_row"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_crm_lead_close_on_stage"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_is_won  boolean;
  v_is_lost boolean;
begin
  if tg_op = 'UPDATE'
     and new.stage_id is not distinct from old.stage_id
     and new.status   is not distinct from old.status then
    return new;
  end if;

  select is_won, is_lost into v_is_won, v_is_lost
    from public.crm_stages where id = new.stage_id;

  if v_is_won then
    new.status := 'won';
    new.closed_at := coalesce(new.closed_at, now());
  elsif v_is_lost then
    new.status := 'lost';
    new.closed_at := coalesce(new.closed_at, now());
  else
    if tg_op = 'UPDATE' and old.status in ('won','lost') then
      new.status := 'open';
      new.closed_at := null;
    end if;
  end if;
  return new;
end$$;


ALTER FUNCTION "public"."fn_crm_lead_close_on_stage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_decrypt_oauth"("ciphertext" "bytea") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  k text := current_setting('app.nuvemshop_oauth_key', true);
begin
  return pgp_sym_decrypt(ciphertext, k);
end$$;


ALTER FUNCTION "public"."fn_decrypt_oauth"("ciphertext" "bytea") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_emit_channel_session_status_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  perform public.fn_log_event(
    new.organization_id, 'channel_session.status_changed',
    jsonb_build_object(
      'channel_session_id', new.id, 'from_status', old.status, 'to_status', new.status,
      'status_reason', new.status_reason, 'phone_number', new.phone_number
    )
  );
  return new;
end$$;


ALTER FUNCTION "public"."fn_emit_channel_session_status_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_emit_event_on_lead_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if tg_op = 'INSERT' then
    perform public.fn_log_event(
      new.organization_id, 'lead.created',
      jsonb_build_object('lead_id', new.id, 'pipeline_id', new.pipeline_id,
                         'stage_id', new.stage_id, 'contact_id', new.contact_id,
                         'source', new.source)
    );
    return new;
  end if;

  if new.stage_id is distinct from old.stage_id then
    perform public.fn_log_event(
      new.organization_id, 'lead.stage_changed',
      jsonb_build_object('lead_id', new.id, 'from_stage_id', old.stage_id, 'to_stage_id', new.stage_id)
    );
  end if;

  if new.status is distinct from old.status then
    if new.status = 'won' then
      perform public.fn_log_event(new.organization_id, 'lead.won',
        jsonb_build_object('lead_id', new.id, 'value_cents', new.value_cents));
    elsif new.status = 'lost' then
      perform public.fn_log_event(new.organization_id, 'lead.lost',
        jsonb_build_object('lead_id', new.id, 'lost_reason', new.lost_reason));
    elsif new.status = 'open' then
      perform public.fn_log_event(new.organization_id, 'lead.reopened',
        jsonb_build_object('lead_id', new.id));
    end if;
  end if;

  if new.owner_user_id is distinct from old.owner_user_id then
    perform public.fn_log_event(new.organization_id, 'lead.assigned',
      jsonb_build_object('lead_id', new.id, 'from_user_id', old.owner_user_id, 'to_user_id', new.owner_user_id));
  end if;

  return new;
end$$;


ALTER FUNCTION "public"."fn_emit_event_on_lead_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_emit_message_event"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_event text;
begin
  if new.direction = 'inbound' then
    v_event := 'message.received';
  else
    v_event := case new.status
                 when 'sending' then 'message.sending'
                 when 'sent' then 'message.sent'
                 when 'failed' then 'message.failed'
                 else 'message.outbound'
               end;
  end if;

  perform public.fn_log_event(
    new.organization_id, v_event,
    jsonb_build_object(
      'message_id', new.id, 'conversation_id', new.conversation_id,
      'contact_id', new.contact_id, 'direction', new.direction,
      'type', new.type, 'status', new.status, 'external_id', new.external_id,
      'channel_session_id', new.channel_session_id,
      'body_preview', "left"(new.body, 280)
    )
  );
  return new;
end$$;


ALTER FUNCTION "public"."fn_emit_message_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_encrypt_oauth"("plaintext" "text") RETURNS "bytea"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  k text := current_setting('app.nuvemshop_oauth_key', true);
begin
  if k is null or length(k) < 32 then
    raise exception 'NUVEMSHOP_OAUTH_ENCRYPTION_KEY ausente';
  end if;
  return pgp_sym_encrypt(plaintext, k, 'cipher-algo=aes256');
end$$;


ALTER FUNCTION "public"."fn_encrypt_oauth"("plaintext" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_is_platform_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.platform_admins
    where user_id = auth.uid() and revoked_at is null
  );
$$;


ALTER FUNCTION "public"."fn_is_platform_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_lgpd_cascade_redact_contact"("p_organization_id" "uuid", "p_contact_id" "uuid", "p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_already bool;
  v_counts jsonb := '{}'::jsonb;
  v_media_paths text[] := '{}';
  v_anon_label text;
  v_count int;
begin
  select is_anonymized into v_already
    from contacts
    where id = p_contact_id and organization_id = p_organization_id;

  if not found then
    raise exception 'contact not found' using errcode = 'P0002';
  end if;

  if v_already then
    return jsonb_build_object('already_anonymized', true, 'counts', v_counts, 'media_paths', v_media_paths);
  end if;

  v_anon_label := 'Cliente Anonimizado #' || substring(p_contact_id::text from 1 for 8);

  -- Collect media storage paths (we only delete what we own — media_storage_path)
  select coalesce(array_agg(distinct media_storage_path) filter (where media_storage_path is not null), '{}')
    into v_media_paths
    from messages
    where organization_id = p_organization_id
      and conversation_id in (
        select id from conversations
          where contact_id = p_contact_id and organization_id = p_organization_id
      );

  -- 1. contacts (irreversible)
  update contacts set
    name = v_anon_label,
    display_name = v_anon_label,
    email = null,
    -- email_normalized NÃO entra: é GENERATED ALWAYS AS (lower(trim(email)))
    -- e o Postgres recusa escrita nela — a linha acima já a zera por derivação.
    -- Com a atribuição, o cascade INTEIRO abortava e nada era anonimizado.
    phone_number = null,
    cpf_encrypted = null,
    cpf_hash = null,
    birthdate = null,
    is_anonymized = true,
    anonymized_at = now(),
    consent = '{}'::jsonb,
    source_metadata = '{}'::jsonb,
    tags = '{}'::text[],
    updated_at = now()
  where id = p_contact_id and organization_id = p_organization_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('contacts', v_count);

  -- 2. conversations metadata + preview strip
  update conversations set
    metadata = '{}'::jsonb,
    last_message_preview = null,
    updated_at = now()
  where contact_id = p_contact_id and organization_id = p_organization_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('conversations', v_count);

  -- 3. messages: redact body + null media + strip metadata (preserve status/timestamps/conversation_id)
  update messages set
    body = '[mensagem anonimizada]',
    media_url = null,
    media_mime = null,
    media_size_bytes = null,
    media_storage_path = null,
    metadata = '{}'::jsonb,
    updated_at = now()
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('messages', v_count);

  -- 4. crm_lead_activities — strip payload, metadata E reason (migration 0071).
  --    `reason` é texto livre escrito por LLM sobre a conversa do lead: supor que
  --    nunca conterá um nome é a suposição que falha. `evidence` NÃO é limpa —
  --    guarda só ids, e as linhas apontadas são redigidas por conta própria.
  update crm_lead_activities set
    payload = '{}'::jsonb,
    metadata = '{}'::jsonb,
    reason = null
  where organization_id = p_organization_id
    and (
      contact_id = p_contact_id
      or lead_id in (
        select lead_id from crm_lead_links
          where target_kind = 'contact'
            and target_id = p_contact_id
            and organization_id = p_organization_id
      )
      or lead_id in (
        select id from crm_leads
          where contact_id = p_contact_id and organization_id = p_organization_id
      )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('activities', v_count);

  -- 5. crm_leads — strip title/description/custom_fields/source_metadata/tags but PRESERVE pipeline/stage/value
  update crm_leads set
    title = v_anon_label,
    description = null,
    custom_fields = '{}'::jsonb,
    source_metadata = '{}'::jsonb,
    tags = '{}'::text[],
    updated_at = now()
  where organization_id = p_organization_id
    and (
      contact_id = p_contact_id
      or id in (
        select lead_id from crm_lead_links
          where target_kind = 'contact'
            and target_id = p_contact_id
            and organization_id = p_organization_id
      )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('leads', v_count);

  -- 6. orders — PRESERVE values + status + timestamps. Strip personal fields from payload jsonb
  --    and replace customer_external_id with null (FK-safe; soft de-link). Keep contact_id null.
  update orders set
    payload = (coalesce(payload, '{}'::jsonb))
      - 'customer'
      - 'customer_name'
      - 'customer_email'
      - 'customer_phone'
      - 'shipping_address'
      - 'billing_address'
      - 'contact_identification',
    customer_external_id = null,
    contact_id = null,
    is_anonymized = true,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('orders', v_count);

  -- 7. enqueue media for async deletion (idempotent via unique (bucket, object_path))
  if array_length(v_media_paths, 1) > 0 then
    insert into storage_redaction_queue (organization_id, request_id, bucket, object_path)
    select p_organization_id, p_request_id, 'whatsapp-media', path
      from unnest(v_media_paths) as path
      where path is not null and length(path) > 0
    on conflict (bucket, object_path) do nothing;
  end if;

  -- 8. dense audit row
  insert into api_audit_log (organization_id, action, actor_user_id, resource_type, resource_id, metadata, bypassed_rls)
  values (
    p_organization_id,
    'lgpd.redact_executed',
    null,
    'contact',
    p_contact_id,
    jsonb_build_object(
      'cascaded_to', v_counts,
      'media_queued', coalesce(array_length(v_media_paths, 1), 0),
      'request_id', p_request_id
    ),
    true
  );

  return jsonb_build_object(
    'already_anonymized', false,
    'counts', v_counts,
    'media_paths', v_media_paths
  );
end;
$$;


ALTER FUNCTION "public"."fn_lgpd_cascade_redact_contact"("p_organization_id" "uuid", "p_contact_id" "uuid", "p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_log_event"("p_organization_id" "uuid", "p_event_type" "text", "p_payload" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_entity_kind text;
  v_entity_id   uuid;
begin
  -- Derive entity_kind from event_type (e.g. 'lead.created' -> 'lead')
  v_entity_kind := split_part(p_event_type, '.', 1);
  v_entity_id   := (p_payload ->> 'lead_id')::uuid;
  if v_entity_id is null then
    v_entity_id := (p_payload ->> (v_entity_kind || '_id'))::uuid;
  end if;

  return public.emit_event(
    p_event_type,
    v_entity_kind,
    v_entity_id,
    p_payload,
    '{}'::jsonb,
    p_organization_id
  );
end $$;


ALTER FUNCTION "public"."fn_log_event"("p_organization_id" "uuid", "p_event_type" "text", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_publish_ai_agent_version"("p_org_id" "uuid", "p_agent_id" "uuid", "p_version_id" "uuid") RETURNS TABLE("agent_id" "uuid", "version_id" "uuid", "previous_version_id" "uuid", "published_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_agent record;
  v_version record;
  v_credential record;
  v_session record;
  v_model_count integer;
  v_previous_version_id uuid;
  v_published_at timestamptz := now();
begin
  select a.id, a.organization_id, a.published_version_id, a.archived_at
    into v_agent
  from public.ai_agents a
  where a.id = p_agent_id
  for update;

  if not found then
    raise exception 'agent_not_found' using errcode = 'P0001';
  end if;
  if v_agent.organization_id <> p_org_id then
    raise exception 'agent_not_found' using errcode = 'P0001';
  end if;
  if v_agent.archived_at is not null then
    raise exception 'agent_archived' using errcode = 'P0001';
  end if;

  select v.id, v.organization_id, v.agent_id, v.status, v.provider, v.model,
         v.credential_id, v.channel_session_id
    into v_version
  from public.ai_agent_versions v
  where v.id = p_version_id
  for update;

  if not found then
    raise exception 'version_not_found' using errcode = 'P0001';
  end if;
  if v_version.agent_id <> p_agent_id or v_version.organization_id <> p_org_id then
    raise exception 'version_not_found' using errcode = 'P0001';
  end if;
  if v_version.status not in ('draft', 'superseded') then
    raise exception 'version_invalid_state' using errcode = 'P0001';
  end if;

  if v_version.credential_id is null then
    raise exception 'credential_missing' using errcode = 'P0001';
  end if;

  select c.id, c.organization_id, c.provider, c.is_active, c.validated_at
    into v_credential
  from public.ai_provider_credentials c
  where c.id = v_version.credential_id;

  if not found or v_credential.organization_id <> p_org_id then
    raise exception 'credential_not_found' using errcode = 'P0001';
  end if;
  if not v_credential.is_active then
    raise exception 'credential_inactive' using errcode = 'P0001';
  end if;
  if v_credential.validated_at is null then
    raise exception 'credential_not_validated' using errcode = 'P0001';
  end if;
  if v_credential.provider <> v_version.provider then
    raise exception 'credential_provider_mismatch' using errcode = 'P0001';
  end if;

  select s.id, s.organization_id, s.status
    into v_session
  from public.channel_sessions s
  where s.id = v_version.channel_session_id;

  if not found or v_session.organization_id <> p_org_id then
    raise exception 'channel_session_not_found' using errcode = 'P0001';
  end if;
  if v_session.status <> 'WORKING' then
    raise exception 'channel_session_offline' using errcode = 'P0001';
  end if;

  select count(*)
    into v_model_count
  from public.ai_models m
  where m.provider = v_version.provider
    and m.model_id = v_version.model
    and m.deprecated_at is null;

  if v_model_count = 0 then
    raise exception 'model_not_found' using errcode = 'P0001';
  end if;

  v_previous_version_id := v_agent.published_version_id;

  if v_previous_version_id is not null and v_previous_version_id <> p_version_id then
    update public.ai_agent_versions
       set status = 'superseded', superseded_at = v_published_at
     where id = v_previous_version_id;
  end if;

  update public.ai_agent_versions
     set status = 'published',
         published_at = v_published_at,
         superseded_at = null
   where id = p_version_id;

  update public.ai_agents
     set published_version_id = p_version_id,
         updated_at = v_published_at
   where id = p_agent_id;

  return query
    select p_agent_id, p_version_id, v_previous_version_id, v_published_at;
end;
$$;


ALTER FUNCTION "public"."fn_publish_ai_agent_version"("p_org_id" "uuid", "p_agent_id" "uuid", "p_version_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."fn_publish_ai_agent_version"("p_org_id" "uuid", "p_agent_id" "uuid", "p_version_id" "uuid") IS 'EPIC-13 S-13.06 (fixed in 0025): atomic Save/Publish flip. Column refs qualified to avoid ambiguity with RETURNS TABLE OUT params.';



CREATE OR REPLACE FUNCTION "public"."fn_role_at_least"("p_org" "uuid", "p_min" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  with levels(role, lvl) as (
    values ('viewer',1),('agent',2),('manager',3),('admin',4)
  )
  select coalesce(
    (select user_lvl.lvl >= min_lvl.lvl
     from levels user_lvl
     join levels min_lvl on min_lvl.role = p_min
     where user_lvl.role = public.fn_user_role_in_org(p_org)),
    false
  );
$$;


ALTER FUNCTION "public"."fn_role_at_least"("p_org" "uuid", "p_min" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_seed_default_pipeline_for_org"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_pipeline_id uuid;
  v_position numeric := 1000;
  r record;
begin
  insert into public.crm_pipelines (organization_id, name, slug, is_default, position)
  values (new.id, 'Pedidos', 'pedidos', true, 1000)
  returning id into v_pipeline_id;

  for r in
    select * from (values
      ('Carrinho abandonado',  'carrinho_abandonado',  false, false),
      ('Aguardando pagamento', 'aguardando_pagamento', false, false),
      ('Pago',                 'pago',                 true,  false),
      ('Em separação',        'em_separacao',         false, false),
      ('Enviado',              'enviado',              false, false),
      ('Entregue',             'entregue',             false, false),
      ('Pós-venda',           'pos_venda',            false, false),
      ('Cancelado',            'cancelado',            false, true)
    ) as t(stage_name, stage_slug, won, lost)
  loop
    insert into public.crm_stages (organization_id, pipeline_id, name, slug, position, is_won, is_lost)
    values (new.id, v_pipeline_id, r.stage_name, r.stage_slug, v_position, r.won, r.lost);
    v_position := v_position + 1000;
  end loop;

  return new;
end$$;


ALTER FUNCTION "public"."fn_seed_default_pipeline_for_org"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  new.updated_at := now();
  return new;
end $$;


ALTER FUNCTION "public"."fn_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  new.updated_at := now();
  return new;
end $$;


ALTER FUNCTION "public"."fn_touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_update_budget_consumption"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.ai_budgets (organization_id, current_month_consumed_cents)
  values (NEW.organization_id, coalesce(NEW.cost_cents, 0))
  on conflict (organization_id) do update
  set current_month_consumed_cents =
        public.ai_budgets.current_month_consumed_cents
        + coalesce(NEW.cost_cents, 0),
      updated_at = now();
  return NEW;
end;
$$;


ALTER FUNCTION "public"."fn_update_budget_consumption"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_update_last_activity_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  update public.crm_leads
     set last_activity_at = greatest(coalesce(last_activity_at, '-infinity'::timestamptz), new.performed_at)
   where id = new.lead_id;

  if new.contact_id is not null then
    update public.contacts
       set last_activity_at = greatest(coalesce(last_activity_at, '-infinity'::timestamptz), new.performed_at)
     where id = new.contact_id;
  end if;
  return new;
end$$;


ALTER FUNCTION "public"."fn_update_last_activity_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_user_org_ids"() RETURNS SETOF "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select organization_id from public.user_organizations
  where user_id = auth.uid() and revoked_at is null;
$$;


ALTER FUNCTION "public"."fn_user_org_ids"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_user_role_in"("p_org" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case public.fn_user_role_in_org(p_org)
    when 'viewer'  then 1
    when 'agent'   then 2
    when 'manager' then 3
    when 'admin'   then 4
    else 0
  end;
$$;


ALTER FUNCTION "public"."fn_user_role_in"("p_org" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_user_role_in_org"("p_org" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select role from public.user_organizations
  where user_id = auth.uid() and organization_id = p_org and revoked_at is null
  limit 1;
$$;


ALTER FUNCTION "public"."fn_user_role_in_org"("p_org" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_validate_activity_lead_org"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_org uuid;
begin
  select organization_id into v_org from public.crm_leads where id = new.lead_id;
  if v_org is null then
    raise exception 'lead_not_found' using errcode = '23503';
  end if;
  if v_org <> new.organization_id then
    raise exception 'lead_org_mismatch' using errcode = '23514';
  end if;
  return new;
end$$;


ALTER FUNCTION "public"."fn_validate_activity_lead_org"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_validate_lost_reason_required"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_canonical text[] := array['requested_by_customer','price','no_response','product_unavailable',
                              'cancelled_by_store','cancelled_by_customer','payment_failed','other'];
  v_pipeline_extra text[];
begin
  if new.status = 'lost' then
    if new.lost_reason is null or length(new.lost_reason) = 0 then
      raise exception 'lost_reason_required' using errcode = '22023';
    end if;

    select coalesce(
      array(select jsonb_array_elements_text(settings->'lost_reasons')), '{}'::text[]
    ) into v_pipeline_extra
    from public.crm_pipelines where id = new.pipeline_id;

    if not (new.lost_reason = any (v_canonical) or new.lost_reason = any (v_pipeline_extra)) then
      raise exception 'lost_reason_invalid: %', new.lost_reason using errcode = '22023';
    end if;
  end if;
  return new;
end$$;


ALTER FUNCTION "public"."fn_validate_lost_reason_required"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."midpoint"("p_prev" numeric, "p_next" numeric) RETURNS numeric
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select case
    when p_prev is null and p_next is null then 1000::numeric
    when p_prev is null then p_next - 1
    when p_next is null then p_prev + 1
    else (p_prev + p_next) / 2
  end
$$;


ALTER FUNCTION "public"."midpoint"("p_prev" numeric, "p_next" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."retrieve_top_k_chunks"("p_organization_id" "uuid", "p_kb_version_id" "uuid", "p_embedding" "public"."vector", "p_k" integer DEFAULT 5, "p_threshold" real DEFAULT 0.72) RETURNS TABLE("chunk_id" "uuid", "knowledge_source_id" "uuid", "content" "text", "similarity" real, "metadata" "jsonb")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select
    c.id as chunk_id,
    c.knowledge_source_id,
    c.content,
    (1 - (c.embedding <=> p_embedding))::real as similarity,
    c.metadata
  from public.ai_chunks c
  where c.organization_id = p_organization_id
    and c.kb_version_id   = p_kb_version_id
    and (1 - (c.embedding <=> p_embedding)) >= p_threshold
  order by c.embedding <=> p_embedding asc
  limit greatest(p_k, 0);
$$;


ALTER FUNCTION "public"."retrieve_top_k_chunks"("p_organization_id" "uuid", "p_kb_version_id" "uuid", "p_embedding" "public"."vector", "p_k" integer, "p_threshold" real) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."retrieve_top_k_chunks"("p_organization_id" "uuid", "p_kb_version_id" "uuid", "p_embedding" "public"."vector", "p_k" integer, "p_threshold" real) IS 'Top-K cosine similarity over ai_chunks. SECURITY DEFINER + programmatic org_id filter. Caller must validate p_organization_id matches authenticated tenant.';

-- `rls_auto_enable()` (event trigger candidato para ligar RLS automaticamente em
-- toda CREATE TABLE) foi removida em 2026-08-27: nunca existiu um `CREATE EVENT
-- TRIGGER ... EXECUTE FUNCTION rls_auto_enable()` em lugar nenhum do baseline ou
-- das migrations, então a função nunca foi de fato invocada pelo Postgres — e,
-- sendo do tipo `event_trigger`, também não pode ser chamada manualmente via
-- SQL. Era uma promessa de proteção automática que o código nunca cumpriu; quem
-- lesse o baseline podia concluir, errado, que tabela nova nascia com RLS
-- ligada sozinha. A garantia real de isolamento por tabela é comportamental
-- (tests/invariants/rls-isolation.test.ts + rls-completude-varredura.test.ts),
-- não um event trigger. Ligar o event trigger de verdade é mudança de
-- comportamento de runtime do banco e mereceria revisão própria — não esta.

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ai_agent_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "agent_version_id" "uuid" NOT NULL,
    "conversation_id" "uuid",
    "contact_id" "uuid",
    "channel_session_id" "uuid",
    "inbound_message_id" "uuid",
    "outbound_message_id" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "abort_reason" "text",
    "error_code" "text",
    "error_message" "text",
    "tokens_in" integer DEFAULT 0 NOT NULL,
    "tokens_out" integer DEFAULT 0 NOT NULL,
    "cost_cents" numeric(10,4) DEFAULT 0 NOT NULL,
    "latency_ms" integer,
    "steps_count" integer DEFAULT 0 NOT NULL,
    "tool_calls" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_dry_run" boolean DEFAULT false NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ai_agent_runs_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'running'::"text", 'completed'::"text", 'failed'::"text", 'aborted'::"text", 'handoff'::"text"])))
);


ALTER TABLE "public"."ai_agent_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_agent_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "version_number" integer NOT NULL,
    "system_prompt" "text" NOT NULL,
    "provider" "text" NOT NULL,
    "model" "text" NOT NULL,
    "credential_id" "uuid",
    "tool_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "trigger_config" "jsonb" DEFAULT "jsonb_build_object"('events', "jsonb_build_array"('message'), 'filters', "jsonb_build_object"('ignore_groups', true, 'ignore_self', true, 'keyword_regex', NULL::"unknown", 'business_hours', NULL::"unknown"), 'concurrency', 'one_per_conversation') NOT NULL,
    "channel_session_id" "uuid" NOT NULL,
    "max_steps" integer DEFAULT 10 NOT NULL,
    "token_budget" integer DEFAULT 50000 NOT NULL,
    "cost_budget_cents" integer DEFAULT 50 NOT NULL,
    "history_message_window" integer DEFAULT 20 NOT NULL,
    "history_token_window" integer DEFAULT 8000 NOT NULL,
    "handoff_keywords" "text"[] DEFAULT ARRAY['falar com humano'::"text", 'atendente'::"text", 'pessoa real'::"text"] NOT NULL,
    "handoff_tool_enabled" boolean DEFAULT true NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "published_at" timestamp with time zone,
    "superseded_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "ai_agent_versions_cost_budget_cents_check" CHECK ((("cost_budget_cents" >= 1) AND ("cost_budget_cents" <= 10000))),
    CONSTRAINT "ai_agent_versions_max_steps_check" CHECK ((("max_steps" >= 1) AND ("max_steps" <= 25))),
    CONSTRAINT "ai_agent_versions_provider_check" CHECK (("provider" = ANY (ARRAY['anthropic'::"text", 'openai'::"text", 'google'::"text"]))),
    CONSTRAINT "ai_agent_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'superseded'::"text", 'archived'::"text"]))),
    CONSTRAINT "ai_agent_versions_token_budget_check" CHECK ((("token_budget" >= 1000) AND ("token_budget" <= 500000)))
);


ALTER TABLE "public"."ai_agent_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_agents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "is_default" boolean DEFAULT false NOT NULL,
    "model" "text" DEFAULT 'anthropic/claude-sonnet-4-6'::"text" NOT NULL,
    "system_prompt" "text" NOT NULL,
    "config" "jsonb" DEFAULT "jsonb_build_object"('temperature', 0.3, 'max_tokens', 1024, 'rag_top_k', 5, 'rag_similarity_threshold', 0.72, 'context_message_window', 20, 'confidence_threshold', 0.55, 'sentiment_threshold', 0.3, 'zero_data_retention', false) NOT NULL,
    "guardrails" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "active_kb_version_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "published_version_id" "uuid",
    "priority" integer DEFAULT 0 NOT NULL,
    "archived_at" timestamp with time zone,
    "kind" "text" DEFAULT 'rag_bot'::"text" NOT NULL,
    CONSTRAINT "ai_agents_kind_check" CHECK (("kind" = ANY (ARRAY['rag_bot'::"text", 'mcp_agent'::"text"])))
);


ALTER TABLE "public"."ai_agents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_budgets" (
    "organization_id" "uuid" NOT NULL,
    "monthly_limit_cents" integer DEFAULT 5000 NOT NULL,
    "action_at_100pct" "text" DEFAULT 'throttle'::"text" NOT NULL,
    "alarm_threshold_pct" integer DEFAULT 80 NOT NULL,
    "current_month_consumed_cents" numeric(12,4) DEFAULT 0 NOT NULL,
    "current_period_start" "date" DEFAULT ("date_trunc"('month'::"text", "now"()))::"date" NOT NULL,
    "last_alarm_sent_at" timestamp with time zone,
    "is_throttled" boolean DEFAULT false NOT NULL,
    "is_disabled" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ai_budgets_action_at_100pct_check" CHECK (("action_at_100pct" = ANY (ARRAY['throttle'::"text", 'disable'::"text"]))),
    CONSTRAINT "ai_budgets_alarm_threshold_pct_check" CHECK ((("alarm_threshold_pct" >= 50) AND ("alarm_threshold_pct" <= 99)))
);


ALTER TABLE "public"."ai_budgets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_chunks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "knowledge_source_id" "uuid" NOT NULL,
    "kb_version_id" "uuid" NOT NULL,
    "position" integer NOT NULL,
    "content" "text" NOT NULL,
    "content_hash" "text" NOT NULL,
    "token_count" integer NOT NULL,
    "embedding" "public"."vector"(1536) NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_chunks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_faq_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "knowledge_source_id" "uuid" NOT NULL,
    "question" "text" NOT NULL,
    "answer" "text" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "locale" "text" DEFAULT 'pt-BR'::"text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_faq_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_invocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "conversation_id" "uuid",
    "message_id" "uuid",
    "invocation_kind" "text" NOT NULL,
    "model" "text" NOT NULL,
    "prompt_tokens" integer DEFAULT 0 NOT NULL,
    "completion_tokens" integer DEFAULT 0 NOT NULL,
    "total_tokens" integer GENERATED ALWAYS AS (("prompt_tokens" + "completion_tokens")) STORED,
    "latency_ms" integer NOT NULL,
    "cost_cents" numeric(10,4) DEFAULT 0 NOT NULL,
    "finish_reason" "text",
    "citations" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "prompt_blob_path" "text",
    "response_blob_path" "text",
    "error_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ai_invocations_invocation_kind_check" CHECK (("invocation_kind" = ANY (ARRAY['bot_respond'::"text", 'sentiment_classify'::"text", 'triage_classify'::"text", 'embedding_generate'::"text"])))
);


ALTER TABLE "public"."ai_invocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_knowledge_sources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "source_type" "text" NOT NULL,
    "source_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "last_indexed_at" timestamp with time zone,
    "last_index_status" "text",
    "last_index_error" "text",
    "chunks_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" DEFAULT ''::"text" NOT NULL,
    "status" "text" DEFAULT 'ready'::"text" NOT NULL,
    "ingested_at" timestamp with time zone,
    CONSTRAINT "ai_knowledge_sources_last_index_status_check" CHECK (("last_index_status" = ANY (ARRAY['success'::"text", 'partial'::"text", 'failed'::"text"]))),
    CONSTRAINT "ai_knowledge_sources_source_type_check" CHECK (("source_type" = ANY (ARRAY['faq'::"text", 'policy'::"text", 'catalog'::"text", 'conversations'::"text", 'conversation'::"text", 'nuvemshop_catalog'::"text"]))),
    CONSTRAINT "ai_knowledge_sources_status_check" CHECK (("status" = ANY (ARRAY['ready'::"text", 'archived'::"text", 'building'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."ai_knowledge_sources" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_knowledge_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "agent_id" "uuid" NOT NULL,
    "version_number" integer NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT false NOT NULL,
    "sources_snapshot" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "total_chunks" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "activated_at" timestamp with time zone,
    "activated_by" "uuid",
    "status" "text" DEFAULT 'building'::"text",
    "error_message" "text",
    "indexed_at" timestamp with time zone,
    CONSTRAINT "ai_knowledge_versions_status_check" CHECK (("status" = ANY (ARRAY['building'::"text", 'ready'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."ai_knowledge_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_models" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider" "text" NOT NULL,
    "model_id" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "context_window" integer,
    "input_price_per_million_cents" integer,
    "output_price_per_million_cents" integer,
    "supports_tools" boolean DEFAULT true NOT NULL,
    "is_default_for_provider" boolean DEFAULT false NOT NULL,
    "deprecated_at" timestamp with time zone,
    "released_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "ai_models_provider_check" CHECK (("provider" = ANY (ARRAY['anthropic'::"text", 'openai'::"text", 'google'::"text"])))
);


ALTER TABLE "public"."ai_models" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_pricing" (
    "model" "text" NOT NULL,
    "prompt_cents_per_million_tokens" numeric(10,4),
    "completion_cents_per_million_tokens" numeric(10,4),
    "embedding_cents_per_million_tokens" numeric(10,4),
    "effective_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "superseded_at" timestamp with time zone,
    "notes" "text"
);


ALTER TABLE "public"."ai_pricing" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_provider_credentials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "label" "text" NOT NULL,
    "api_key_encrypted" "bytea" NOT NULL,
    "api_key_iv" "bytea" NOT NULL,
    "api_key_tag" "bytea" NOT NULL,
    "api_key_last4" "text" NOT NULL,
    "validated_at" timestamp with time zone,
    "validation_error" "text",
    "models_available" "text"[],
    "is_active" boolean DEFAULT true NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ai_provider_credentials_provider_check" CHECK (("provider" = ANY (ARRAY['anthropic'::"text", 'openai'::"text", 'google'::"text"])))
);


ALTER TABLE "public"."ai_provider_credentials" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."ai_provider_credentials_safe" WITH ("security_invoker"='true') AS
 SELECT "id",
    "organization_id",
    "provider",
    "label",
    "api_key_last4",
    "validated_at",
    "validation_error",
    "models_available",
    "is_active",
    "created_by",
    "created_at",
    "updated_at"
   FROM "public"."ai_provider_credentials";


ALTER VIEW "public"."ai_provider_credentials_safe" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."api_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid",
    "actor_user_id" "uuid",
    "actor_api_token_id" "uuid",
    "acting_as_platform_admin" boolean DEFAULT false NOT NULL,
    "actor_ip" "inet",
    "actor_user_agent" "text",
    "action" "text" NOT NULL,
    "resource_type" "text",
    "resource_id" "uuid",
    "request_id" "text",
    "bypassed_rls" boolean DEFAULT false NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."api_audit_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."api_audit_log" IS 'L-10: Append-only. Retencao 5 anos.';



CREATE TABLE IF NOT EXISTS "public"."api_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "prefix" "text" NOT NULL,
    "token_hash" "bytea" NOT NULL,
    "scopes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "last_used_at" timestamp with time zone,
    "last_used_ip" "inet",
    "expires_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "revoked_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."api_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."channel_session_warmup" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "channel_session_id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "day" "date" NOT NULL,
    "messages_sent" integer DEFAULT 0 NOT NULL,
    "messages_received" integer DEFAULT 0 NOT NULL,
    "unique_contacts" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."channel_session_warmup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."channel_sessions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "waha_session_name" "text" NOT NULL,
    "engine" "text" DEFAULT 'NOWEB'::"text" NOT NULL,
    "webhook_path_token" "text" DEFAULT "replace"(("extensions"."uuid_generate_v4"())::"text", '-'::"text", ''::"text") NOT NULL,
    "webhook_secret_encrypted" "bytea" NOT NULL,
    "status" "text" DEFAULT 'STARTING'::"text" NOT NULL,
    "status_reason" "text",
    "phone_number" "text",
    "display_name" "text",
    "last_health_check_at" timestamp with time zone,
    "last_status_change_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "consecutive_health_fails" integer DEFAULT 0 NOT NULL,
    "daily_message_limit" integer DEFAULT 300 NOT NULL,
    "warmup_started_at" timestamp with time zone,
    "warmup_completed_at" timestamp with time zone,
    "is_warmup_complete" boolean GENERATED ALWAYS AS (("warmup_completed_at" IS NOT NULL)) STORED,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "channel_sessions_engine_check" CHECK (("engine" = ANY (ARRAY['NOWEB'::"text", 'WEBJS'::"text"]))),
    CONSTRAINT "channel_sessions_status_check" CHECK (("status" = ANY (ARRAY['STARTING'::"text", 'SCAN_QR_CODE'::"text", 'WORKING'::"text", 'STOPPED'::"text", 'FAILED'::"text"])))
);


ALTER TABLE "public"."channel_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "name" "text",
    "display_name" "text",
    "email" "text",
    "email_normalized" "text" GENERATED ALWAYS AS ("lower"(TRIM(BOTH FROM "email"))) STORED,
    "phone_number" "text",
    "cpf_encrypted" "bytea",
    "cpf_hash" "text",
    "birthdate" "date",
    "is_blocked" boolean DEFAULT false NOT NULL,
    "blocked_reason" "text",
    "blocked_at" timestamp with time zone,
    "is_anonymized" boolean DEFAULT false NOT NULL,
    "anonymized_at" timestamp with time zone,
    "is_merged_into" "uuid",
    "merged_at" timestamp with time zone,
    "consent" "jsonb" DEFAULT "jsonb_build_object"('marketing', "jsonb_build_object"('granted_at', NULL::"unknown", 'source', NULL::"unknown", 'version', NULL::"unknown"), 'transactional', "jsonb_build_object"('granted_at', NULL::"unknown", 'source', NULL::"unknown", 'version', NULL::"unknown"), 'profiling', "jsonb_build_object"('granted_at', NULL::"unknown", 'source', NULL::"unknown", 'version', NULL::"unknown")) NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "source_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by_user_id" "uuid",
    "last_activity_at" timestamp with time zone,
    "force_human" boolean DEFAULT false NOT NULL,
    CONSTRAINT "contacts_anonymized_locked" CHECK ((("is_anonymized" = false) OR (("is_anonymized" = true) AND ("anonymized_at" IS NOT NULL)))),
    CONSTRAINT "contacts_cpf_consistency" CHECK ((("cpf_encrypted" IS NULL) = ("cpf_hash" IS NULL))),
    CONSTRAINT "contacts_email_format" CHECK ((("email" IS NULL) OR ("email" ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::"text"))),
    CONSTRAINT "contacts_phone_e164_format" CHECK ((("phone_number" IS NULL) OR ("phone_number" ~ '^\+\d{8,15}$'::"text")))
);


ALTER TABLE "public"."contacts" OWNER TO "postgres";


COMMENT ON TABLE "public"."contacts" IS 'Pessoa fisica no escopo de um tenant. CPF criptografado at-rest. is_anonymized irreversivel (L-04).';



CREATE TABLE IF NOT EXISTS "public"."conversations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "channel_session_id" "uuid" NOT NULL,
    "channel" "text" DEFAULT 'whatsapp'::"text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "status_changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "assigned_to_user_id" "uuid",
    "assigned_at" timestamp with time zone,
    "last_inbound_at" timestamp with time zone,
    "last_outbound_at" timestamp with time zone,
    "last_message_at" timestamp with time zone,
    "last_message_preview" "text",
    "unread_count_for_assignee" integer DEFAULT 0 NOT NULL,
    "is_group" boolean DEFAULT false NOT NULL,
    "group_chat_id" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "bot_silenced_until" timestamp with time zone,
    "last_handoff_at" timestamp with time zone,
    "last_handoff_reason" "text",
    "usable_for_rag" boolean DEFAULT false NOT NULL,
    "usable_for_rag_marked_at" timestamp with time zone,
    "usable_for_rag_marked_by" "uuid",
    "rag_review_status" "text",
    CONSTRAINT "conversations_channel_check" CHECK (("channel" = 'whatsapp'::"text")),
    CONSTRAINT "conversations_rag_review_status_check" CHECK ((("rag_review_status" IS NULL) OR ("rag_review_status" = ANY (ARRAY['pending_review'::"text", 'ingested'::"text", 'skipped'::"text"])))),
    CONSTRAINT "conversations_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'pending'::"text", 'resolved'::"text", 'claimed'::"text", 'ai_handling'::"text", 'closed'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."conversations" OWNER TO "postgres";


COMMENT ON CONSTRAINT "conversations_status_check" ON "public"."conversations" IS 'Accepts both legacy (open/pending/resolved) + EPIC-03 spec (claimed/ai_handling/closed/archived). UI/API normalizes; future migration may consolidate.';



CREATE TABLE IF NOT EXISTS "public"."crm_lead_activities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "contact_id" "uuid",
    "source_module" "text" NOT NULL,
    "source_id" "uuid",
    "type" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "performed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "performed_by_user_id" "uuid"
);


ALTER TABLE "public"."crm_lead_activities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crm_lead_links" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "target_kind" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "link_kind" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by_user_id" "uuid",
    CONSTRAINT "crm_lead_links_target_kind_enum" CHECK (("target_kind" = ANY (ARRAY['order'::"text", 'conversation'::"text", 'message'::"text", 'appointment'::"text", 'contact'::"text", 'lead'::"text", 'external'::"text"])))
);


ALTER TABLE "public"."crm_lead_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crm_leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "pipeline_id" "uuid" NOT NULL,
    "stage_id" "uuid" NOT NULL,
    "contact_id" "uuid",
    "title" "text" NOT NULL,
    "description" "text",
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "lost_reason" "text",
    "position_in_stage" numeric DEFAULT 1000 NOT NULL,
    "value_cents" bigint,
    "currency" "text" DEFAULT 'BRL'::"text",
    "owner_user_id" "uuid",
    "assigned_at" timestamp with time zone,
    "last_activity_at" timestamp with time zone,
    "expected_close_date" "date",
    "closed_at" timestamp with time zone,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "source_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "external_id" "text",
    "custom_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by_user_id" "uuid",
    CONSTRAINT "crm_leads_closed_at_consistency" CHECK (((("status" = 'open'::"text") AND ("closed_at" IS NULL)) OR (("status" = ANY (ARRAY['won'::"text", 'lost'::"text"])) AND ("closed_at" IS NOT NULL)))),
    CONSTRAINT "crm_leads_currency_iso" CHECK ((("currency" IS NULL) OR ("currency" ~ '^[A-Z]{3}$'::"text"))),
    CONSTRAINT "crm_leads_lost_reason_required" CHECK ((("status" <> 'lost'::"text") OR (("lost_reason" IS NOT NULL) AND ("length"("lost_reason") > 0)))),
    CONSTRAINT "crm_leads_status_enum" CHECK (("status" = ANY (ARRAY['open'::"text", 'won'::"text", 'lost'::"text"])))
);


ALTER TABLE "public"."crm_leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crm_pipelines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "description" "text",
    "is_default" boolean DEFAULT false NOT NULL,
    "is_archived" boolean DEFAULT false NOT NULL,
    "position" numeric DEFAULT 1000 NOT NULL,
    "vocabulary" "jsonb" DEFAULT "jsonb_build_object"('lead', 'Cliente', 'lead_plural', 'Clientes', 'deal', 'Pedido', 'deal_plural', 'Pedidos', 'won', 'Pago', 'lost', 'Cancelado', 'stage', 'Etapa', 'stage_plural', 'Etapas') NOT NULL,
    "settings" "jsonb" DEFAULT "jsonb_build_object"('fields', '[]'::"jsonb", 'canonical_tags', '[]'::"jsonb", 'lost_reasons', '[]'::"jsonb", 'identity_resolution', "jsonb_build_object"('fields_in_priority_order', "jsonb_build_array"('cpf', 'phone_e164', 'email'))) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "crm_pipelines_slug_format" CHECK (("slug" ~ '^[a-z0-9_-]{2,40}$'::"text"))
);


ALTER TABLE "public"."crm_pipelines" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."crm_stages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "pipeline_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "description" "text",
    "position" numeric NOT NULL,
    "color" "text",
    "is_won" boolean DEFAULT false NOT NULL,
    "is_lost" boolean DEFAULT false NOT NULL,
    "is_archived" boolean DEFAULT false NOT NULL,
    "expected_duration_hours" numeric,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "requires_human" boolean DEFAULT false NOT NULL,
    CONSTRAINT "crm_stages_color_format" CHECK ((("color" IS NULL) OR ("color" ~ '^#[0-9a-fA-F]{6}$'::"text"))),
    CONSTRAINT "crm_stages_slug_format" CHECK (("slug" ~ '^[a-z0-9_-]{2,40}$'::"text")),
    CONSTRAINT "crm_stages_won_lost_mutex" CHECK ((NOT ("is_won" AND "is_lost")))
);


ALTER TABLE "public"."crm_stages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "entity_kind" "text" NOT NULL,
    "entity_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "consumed_by" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "attempts" smallint DEFAULT 0 NOT NULL,
    "last_error" "text",
    "next_attempt_at" timestamp with time zone,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_log_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'done'::"text", 'dead'::"text"]))),
    CONSTRAINT "event_type_format" CHECK (("event_type" ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'::"text"))
);


ALTER TABLE "public"."event_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."event_log" IS 'Bus interno do CRM. Triggers e ServerActions inserem aqui via emit_event(). Workers consomem.';



CREATE TABLE IF NOT EXISTS "public"."idempotency_keys" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "key" "text" NOT NULL,
    "endpoint" "text" NOT NULL,
    "request_hash" "bytea" NOT NULL,
    "status_code" integer,
    "response_body" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '24:00:00'::interval) NOT NULL
);


ALTER TABLE "public"."idempotency_keys" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."incidents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid",
    "type" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "acknowledged_at" timestamp with time zone,
    "acknowledged_by" "uuid",
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "resolution_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "incidents_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'critical'::"text"]))),
    CONSTRAINT "incidents_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'acknowledged'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."incidents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lgpd_requests" …232152 tokens truncated…count);

  -- 8. dense audit row
  insert into api_audit_log (organization_id, action, actor_user_id, resource_type, resource_id, metadata, bypassed_rls)
  values (
    p_organization_id,
    'lgpd.redact_executed',
    null,
    'contact',
    p_contact_id,
    jsonb_build_object(
      'cascaded_to', v_counts,
      'media_queued', coalesce(array_length(v_media_paths, 1), 0),
      'request_id', p_request_id
    ),
    true
  );

  return jsonb_build_object(
    'already_anonymized', false,
    'counts', v_counts,
    'media_paths', v_media_paths
  );
end;
$$;
revoke all on function public.fn_lgpd_cascade_redact_contact(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.fn_lgpd_cascade_redact_contact(uuid,uuid,uuid) to service_role;

notify pgrst, 'reload schema';

-- ---- Conversa de configuração da prospecção (migration 0371) ----
-- The administrator's unfinished setup belongs to the campaign, not to Inbox.
-- Existing rows keep the empty default. Server-only RLS/grants remain unchanged.
alter table public.prospecting_campaigns
  add column if not exists agent_setup jsonb not null default '{}'::jsonb,
  add column if not exists agent_setup_revision bigint not null default 0;
notify pgrst, 'reload schema';

-- ---- provider "zernio_social" nos CHECKs de channel_sessions (migration 0368) ----
--
-- NÃO HÁ BLOCO AQUI, e a ausência é decisão: `zernio_social` foi somado ao
-- bloco ÚNICO das duas constraints, lá em cima (procure por
-- `channel_sessions_provider_check`). A doutrina é "uma constraint, um bloco"
-- (`tests/unit/baseline-constraint-reconstruida.test.ts`), e ela existe por um
-- motivo de produção: cada drop+add repetido é mais uma janela em que a tabela
-- fica SEM constraint durante o `update.sh` de um cliente, e o último bloco a
-- rodar é quem decide o vocabulário — dois blocos discordando viram um banco
-- que recusa o canal novo com o script fechando verde.
--
-- Este comentário fica no lugar do bloco porque foi exatamente aqui que a
-- versão anterior deste PR o pôs, e a cerca reprovou (`2x` cada constraint).
-- Quem vier somar o quinto provider: some no bloco de cima, não aqui.



-- ---- remarcar um compromisso já enviado corrige o cliente (migration 0374) ----
-- Gatilho novo `trg_remarcar_corrige_o_envio` (BEFORE UPDATE): quem JÁ recebeu
-- e teve `starts_at`/`time_zone` mudados ganha uma correção autorizada pela
-- mesma pessoa, com espera de 2 min (`nao_antes_de`) para arrastar na grade não
-- virar uma mensagem por arrasto. O enfileirador carrega o `motivo` ao payload.
-- ⚠️ ANTES DA VARREDURA anon. Idempotente.
-- Recorte do PR #803, de @paulolimajr77.

create or replace function public.fn_remarcar_corrige_o_envio()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op <> 'UPDATE' then return new; end if;
 -- Cancelado não recebe correção: avisar cancelamento é outra funcionalidade, e
 -- mandar "o horário mudou" de um compromisso que não existe mais é pior que calar.
 if new.status = 'cancelled' then return new; end if;
 -- Só quem JÁ recebeu. Quem está em `waiting_for_link`/`queued` já vai sair com
 -- o horário novo sozinho, porque o texto é montado no envio.
 if coalesce(new.meeting_delivery->>'state','') <> 'sent' then return new; end if;
 -- APENAS os campos que entram no texto da mensagem. Reagir a qualquer `update`
 -- na linha faria uma edição de TÍTULO mandar mensagem ao cliente.
 if row(new.starts_at, new.time_zone) is not distinct from row(old.starts_at, old.time_zone) then
  return new;
 end if;

 new.meeting_delivery := jsonb_build_object(
   'state','waiting_for_link',
   -- Geração nova: é ela que faz um job anterior reprovar na vigência e se
   -- cancelar sozinho, em vez de duas mensagens saírem.
   'generation', gen_random_uuid(),
   'service_boundary', old.meeting_delivery->'service_boundary',
   'channel_session_id', old.meeting_delivery->>'channel_session_id',
   -- Quem autorizou o envio original autoriza a correção: é a mesma intenção,
   -- corrigida. E a vigência RECONFERE no envio se essa pessoa ainda é a
   -- responsável e ainda tem papel — se não for, a correção não sai e abre aviso
   -- na Central, que é o comportamento certo.
   'authorized_by', old.meeting_delivery->'authorized_by',
   'source_operation_id', gen_random_uuid(),
   'motivo','remarcado',
   'nao_antes_de', (now() + interval '2 minutes')::text);
 new.meeting_delivery_job_id := null;
 return new;
end;$$;
revoke execute on function public.fn_remarcar_corrige_o_envio() from public, anon, authenticated;

drop trigger if exists trg_remarcar_corrige_o_envio on public.calendar_appointments;
create trigger trg_remarcar_corrige_o_envio
  before update on public.calendar_appointments
  for each row execute function public.fn_remarcar_corrige_o_envio();

create or replace function public.fn_meet_delivery_enqueue()
returns trigger language plpgsql security definer set search_path=public as $$
declare jid uuid; b jsonb;
begin
 -- A MESMA ORDEM DE TRAVA das ~20 irmãs: contato PRIMEIRO, job_queue depois.
 -- Sem esta linha, este gatilho já segurava a linha do compromisso (é BEFORE/
 -- AFTER na própria calendar_appointments) e ia travar job_queue sem o mutex do
 -- contato, enquanto fn_meet_redact_contact (0229) pega o mutex do contato e só
 -- então mexe em job_queue. Duas ordens opostas sobre os mesmos dois recursos =
 -- deadlock (40P01) sob concorrência, e quem paga é o cliente com anonimização
 -- LGPD acontecendo enquanto um link de reunião é entregue.
 perform public.fn_service_lock(new.organization_id,new.contact_id);
 -- ⚠️ `status` ENTRA AQUI, e a falta dele era um buraco REAL que só apareceu
 -- ao abrir a entrega para compromisso sem Meet.
 --
 -- A guarda olhava só `meeting_state='cancelled'` — o estado do LINK, não do
 -- compromisso. Enquanto a entrega exigia link pronto isso bastava por
 -- acidente: cancelar o compromisso cancelava o link junto. Sem Meet não há
 -- link para cancelar, e um compromisso CANCELADO passava a enfileirar
 -- entrega. O porteiro do envio recusaria depois (`a.status<>'cancelled'`),
 -- então o cliente não receberia nada — mas o job nasceria para morrer
 -- bloqueado, e a tela mostraria uma entrega a caminho que nunca sai.
 --
 -- Achado do @paulolimajr77, e foi o teste DELE que o pegou aqui.
 if new.status='cancelled' or new.meeting_state='cancelled' or new.meeting_delivery->>'state' in ('blocked','stale') then
  update public.job_queue set status='failed',locked_at=null,locked_by=null,payload='{}',last_error='meet_delivery_stale'
   where organization_id=new.organization_id and id=new.meeting_delivery_job_id and kind='transactional_delivery' and status in ('pending','running');
  return new;
 end if;
 if new.meeting_state='failed' then perform public.fn_meet_notice(new.organization_id,new.id,'meeting_failed');end if;
 -- ⛔ ESPERAR O LINK VALE SÓ ONDE O LOCAL É O MEET.
 --
 -- Esta é a exigência mais fácil de esquecer e a pior de esquecer: num
 -- compromisso PRESENCIAL o `meeting_state` é `not_requested` para sempre,
 -- então a entrega era autorizada, o gatilho passava por aqui, devolvia sem
 -- enfileirar nada, e a entrega ficava em `waiting_for_link` PARA SEMPRE — em
 -- silêncio, sem job, sem aviso e sem erro. Foi o teste do autor que a achou.
 --
 -- Onde o local É o Meet, nada muda: sem link pronto não sai job, porque
 -- mandar uma reunião sem como entrar nela é pior que não mandar.
 if (new.location_kind='google_meet' and new.meeting_state<>'ready')
  or new.meeting_delivery->>'state'<>'waiting_for_link' then return new;end if;
 b:=new.meeting_delivery->'service_boundary';
 if not public.fn_meet_boundary_current(b) then
  update public.calendar_appointments set meeting_delivery=meeting_delivery||'{"state":"stale","error":"service_boundary_stale"}' where organization_id=new.organization_id and id=new.id;
  perform public.fn_meet_notice(new.organization_id,new.id,'service_boundary_stale');return new;
 end if;
 jid:=gen_random_uuid();
 insert into public.job_queue(id,organization_id,contact_id,kind,payload,run_after)
 values(jid,new.organization_id,new.contact_id,'transactional_delivery',jsonb_build_object('appointment_id',new.id,'meeting_request_id',new.meeting_request_id,
  'delivery_generation',new.meeting_delivery->>'generation','service_boundary',b,
  -- O MOTIVO decide a FRASE que o cliente lê. Ausente = `primeiro_envio`,
  -- que é o comportamento de antes desta migration e o certo para toda
  -- entrega que já estava na fila quando ela foi aplicada.
  'motivo',coalesce(new.meeting_delivery->>'motivo','primeiro_envio')),
  -- ANTIRREPETIÇÃO: a correção ESPERA antes de sair, e uma remarcação nova
  -- dentro da janela substitui esta. Sem a espera, arrastar o compromisso na
  -- grade viraria uma mensagem por arrasto.
  coalesce((new.meeting_delivery->>'nao_antes_de')::timestamptz, now()));
 update public.calendar_appointments set meeting_delivery_job_id=jid,meeting_delivery=meeting_delivery||'{"state":"queued"}'
  where organization_id=new.organization_id and id=new.id;
 return new;
end;$$;
revoke all on function public.fn_meet_delivery_enqueue() from public,anon,authenticated;
-- ---- Cache da hierarquia do anúncio (migration 0380) ----
-- Nome do anúncio, do conjunto e da campanha por id de anúncio. Existe porque a
-- conta de anúncios opera em cota baixa e um único anúncio gera centenas de
-- contatos: sem cache, cada ficha aberta repetiria a mesma pergunta. Mesmo
-- desenho server-side-only de ad_insights_connections (0214); ver o cabeçalho da
-- migration 0380 para o racional completo.

create table if not exists public.ad_hierarchy_cache (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  platform text not null,
  ad_id text not null,
  ad_name text,
  adset_id text,
  adset_name text,
  campaign_id text,
  campaign_name text,
  fetched_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ad_hierarchy_cache_platform_conhecida
    check (platform in ('meta_ads', 'google_ads'))
);

create unique index if not exists ad_hierarchy_cache_org_platform_ad_uk
  on public.ad_hierarchy_cache (organization_id, platform, ad_id);

comment on table public.ad_hierarchy_cache is
  'Nome do anúncio, do conjunto e da campanha, guardados por id de anúncio. Existe porque a conta de anúncios opera em cota baixa e um único anúncio gera centenas de contatos: sem cache, cada ficha aberta gastaria uma chamada para repetir a mesma pergunta. Server-side only: RLS ligada sem policies e grants revogados de anon/authenticated.';
comment on column public.ad_hierarchy_cache.ad_id is
  'O identificador do anúncio na plataforma — o mesmo que a ingestão grava em contacts.source_metadata.ad_id. Sem FK: o anúncio é da plataforma e pode ser apagado lá sem aviso.';
comment on column public.ad_hierarchy_cache.fetched_at is
  'Quando a hierarquia foi lida da plataforma. A idade aceitável é decisão do código que lê, não do schema: ela muda com o degrau de cota da conta, e não com a forma do dado.';

alter table public.ad_hierarchy_cache enable row level security;
revoke all on public.ad_hierarchy_cache from anon, authenticated;
grant select, insert, update, delete on public.ad_hierarchy_cache to service_role;

drop trigger if exists trg_ad_hierarchy_cache_updated_at on public.ad_hierarchy_cache;
create trigger trg_ad_hierarchy_cache_updated_at
  before update on public.ad_hierarchy_cache
  for each row execute function public.fn_set_updated_at();

-- ---- VARREDURA anon: função nova nasce exposta em quem ATUALIZA (migration 0116) ----
--
-- ⚠️ DE PROPÓSITO, NENHUMA FUNÇÃO É CRIADA DEPOIS DESTE BLOCO. Apêndice que cria
-- função entra ANTES dele — quem o empurrar para o meio desarma a cura para tudo
-- que vier depois. (O último bloco do arquivo é a chamada das travas do suporte,
-- migration 0274, que não cria função.)
-- Vigiado por `tests/unit/varredura-anon-e-o-ultimo-bloco.test.ts`.
--
-- A 0108 revogou anon numa LISTA de 8 funções, medida num banco instalado do
-- ZERO. Quem ATUALIZA tem outro estado: o `ALTER DEFAULT PRIVILEGES ... GRANT
-- ALL ON FUNCTIONS TO anon` do corpo deste arquivo grava uma entrada em
-- `pg_default_acl` que fica no catálogo PARA SEMPRE, e a partir daí toda função
-- criada em `public` nasce com EXECUTE para anon — inclusive as deste apêndice.
--
-- Medido numa VPS real (2026-08-07), comparando com o que um install fresco
-- produz: 6 definer expostas a anon e 5 a authenticated, entre elas
-- `fn_decrypt_oauth` — alcançável pela anon key, que vai para o browser.
--
-- Lista conserta o estoque e reabre no próximo `create function`. Esta varredura
-- é auto-curativa e roda DEPOIS de tudo que cria função, então cura no mesmo run
-- em que o defeito nasceria. Desfazer o ALTER DEFAULT PRIVILEGES não serve: ele
-- vem do `pg_dump` do Supabase e é reescrito a cada re-aplicação.
--
-- As duas origens de EXECUTE (a mesma lição da 0108): grant DIRETO a anon, que
-- `revoke from public` não remove; e grant a PUBLIC, do qual anon HERDA, que
-- `revoke from anon` não remove. O privilégio EFETIVO de authenticated e
-- service_role é medido ANTES e devolvido depois — tira anon sem tirar leitura.
do $$
declare
  f record;
  tinha_auth boolean;
  tinha_service boolean;
begin
  if to_regrole('anon') is null then
    return;
  end if;

  for f in
    select p.oid, p.oid::regprocedure as assinatura
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
  loop
    tinha_auth := to_regrole('authenticated') is not null
                  and has_function_privilege('authenticated', f.oid, 'EXECUTE');
    tinha_service := to_regrole('service_role') is not null
                     and has_function_privilege('service_role', f.oid, 'EXECUTE');

    execute format('revoke execute on function %s from public, anon', f.assinatura);

    if tinha_auth then
      execute format('grant execute on function %s to authenticated', f.assinatura);
    end if;
    if tinha_service then
      execute format('grant execute on function %s to service_role', f.assinatura);
    end if;
  end loop;
end $$;

-- regra 2 (authenticated): as 5 que o update abriu e o install não abre. Aqui não
-- cabe varredura — `authenticated` PRECISA de EXECUTE nos helpers de RLS e em
-- `retrieve_top_k_chunks` (num install fresco ele tem). É julgamento por função,
-- e o alvo de cada linha é o valor que um install fresco produz, medido.
revoke execute on function public.fn_audit_log_row() from authenticated;
revoke execute on function public.fn_decrypt_oauth(bytea) from authenticated;
revoke execute on function public.fn_encrypt_oauth(text) from authenticated;
revoke execute on function public.fn_lgpd_cascade_redact_contact(uuid, uuid, uuid) from authenticated;
revoke execute on function public.fn_update_budget_consumption() from authenticated;

grant execute on function public.fn_audit_log_row() to service_role;
grant execute on function public.fn_decrypt_oauth(bytea) to service_role;
grant execute on function public.fn_encrypt_oauth(text) to service_role;
grant execute on function public.fn_lgpd_cascade_redact_contact(uuid, uuid, uuid) to service_role;
grant execute on function public.fn_update_budget_consumption() to service_role;


-- ---- Criador provisório sai na entrega (migration 0237) ----
-- As duas funções acima já saíram com a regra; aqui fica só a COLUNA, que é
-- o dado que faltava. Idempotente. NÃO há expurgo retroativo, de propósito:
-- vínculo antigo não tem a marca, e deduzi-la foi o erro que a primeira
-- versão desta regra cometeu (ver o cabeçalho da migration).
alter table public.user_organizations
  add column if not exists provisional_until_handover boolean not null default false;

comment on column public.user_organizations.provisional_until_handover is
  'Este vínculo existe só para a organização não nascer vazia, e sai quando o '
  'dono assumir. Gravado APENAS por fn_create_tenant_with_owner, e apenas '
  'quando o tenant foi criado para OUTRA pessoa (owner_email <> e-mail de quem '
  'cria). Nunca deduzir este valor depois: a ausência dele foi o que fez a '
  'primeira versão desta regra expulsar alguém da própria empresa.';
-- ---- política de cadastro da instalação (migration 0253) ----
create table if not exists public.platform_settings (
  id           smallint    primary key default 1,
  signup_mode  text        not null default 'aberto',
  -- Comportamento da instalação (0331). NULAS de propósito: null = "a
  -- instalação não opinou" e quem responde é o arquivo de ambiente, o que faz
  -- a migration não mudar comportamento de quem nunca abrir a tela.
  orcamento_de_ia              text,
  exigir_assinatura_no_webhook boolean,
  divulgacao_de_pagamento      text,
  promessa_semantica           boolean,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint platform_settings_singleton check (id = 1),
  constraint platform_settings_signup_mode check (signup_mode in ('aberto', 'so_convite')),
  constraint platform_settings_orcamento_de_ia
    check (orcamento_de_ia is null or orcamento_de_ia in ('on', 'avisar', 'off')),
  constraint platform_settings_divulgacao_de_pagamento
    check (divulgacao_de_pagamento is null or divulgacao_de_pagamento in ('inject', 'veto'))
);

comment on table public.platform_settings is
  'Configuração da INSTALAÇÃO (não do tenant) — linha única id=1. Hoje a política de cadastro e o COMPORTAMENTO (orçamento de IA, assinatura de webhook, divulgação de pagamento, conferência de promessa). Coluna nula = a instalação não opinou, e quem responde é o arquivo de ambiente. Lida/escrita apenas server-side (service_role); a ausência da linha significa o default. Ver lib/auth/politica-de-cadastro.ts e lib/instalacao/comportamento.ts.';

comment on column public.platform_settings.signup_mode is
  'aberto = qualquer pessoa cria conta em /signup (comportamento histórico). so_convite = só quem chega com convite válido; sem convite, /signup recusa com tela e /auth/confirm NÃO provisiona organização.';

alter table public.platform_settings enable row level security;

-- ZERO POLICIES, DE PROPÓSITO. Mesma decisão de `platform_branding`: esta linha
-- não pertence a organização nenhuma, então não há predicado de tenant que a
-- isole. RLS ligada sem policy = ninguém alcança pela REST; quem lê é o
-- service_role, que a bypassa, e só a partir do servidor.
revoke all on public.platform_settings from anon, authenticated;
grant select, insert, update on public.platform_settings to service_role;

drop trigger if exists trg_platform_settings_touch on public.platform_settings;
create trigger trg_platform_settings_touch
  before update on public.platform_settings
  for each row execute function public.fn_touch_updated_at();

notify pgrst, 'reload schema';

-- ---- comportamento da instalação (migration 0331) ----
-- O `create table if not exists` acima só age em instalação NOVA: quem já tem
-- `platform_settings` (desde a 0253, v1.25.0) passa por ele sem efeito no
-- `update.sh`, e as quatro colunas nunca nasceriam. Este bloco é o espelho da
-- migration 0331 e é o que as leva a quem ATUALIZA. NULAS e sem default, de
-- propósito: null = "a instalação não opinou", e quem responde é o `.env`.
-- Sem dado a corrigir antes das CHECKs: as colunas nascem nulas, e as CHECKs
-- aceitam null.
alter table public.platform_settings
  add column if not exists orcamento_de_ia              text,
  add column if not exists exigir_assinatura_no_webhook boolean,
  add column if not exists divulgacao_de_pagamento      text,
  add column if not exists promessa_semantica           boolean;

alter table public.platform_settings
  drop constraint if exists platform_settings_orcamento_de_ia;
alter table public.platform_settings
  add constraint platform_settings_orcamento_de_ia
  check (orcamento_de_ia is null or orcamento_de_ia in ('on', 'avisar', 'off'));

alter table public.platform_settings
  drop constraint if exists platform_settings_divulgacao_de_pagamento;
alter table public.platform_settings
  add constraint platform_settings_divulgacao_de_pagamento
  check (divulgacao_de_pagamento is null or divulgacao_de_pagamento in ('inject', 'veto'));

comment on column public.platform_settings.orcamento_de_ia is
  'on = a IA respeita o teto de gasto que cada organização escolheu (default do produto, e o que o .env declara). avisar = a IA responde e apenas avisa quem opera. off = sem proteção de gasto. null = a instalação não opinou; vale AI_BUDGET_ENFORCEMENT do arquivo de ambiente. Só AFROUXA o que a organização escolheu: nunca liga proteção que a empresa não pediu.';

comment on column public.platform_settings.exigir_assinatura_no_webhook is
  'true = toda entrega de webhook do canal precisa vir assinada com o segredo da sessão; sem assinatura (ou com assinatura errada) a entrega é recusada. null = a instalação não opinou; vale WAHA_WEBHOOK_REQUIRE_SIGNATURE do arquivo de ambiente (default do produto: false).';

comment on column public.platform_settings.divulgacao_de_pagamento is
  'inject = o texto de divulgação de pagamento entra na primeira mensagem. veto = o envio sem esse texto é bloqueado e devolvido ao modelo com a razão, para ele reescrever. null = a instalação não opinou; vale DISCLOSURE_MODE do arquivo de ambiente (default do produto: inject).';

comment on column public.platform_settings.promessa_semantica is
  'true = cada envio passa por uma conferência de modelo antes de sair, para não prometer o que a empresa não cumpre (custa uma chamada de modelo por envio). null = a instalação não opinou; vale PROMISE_SEMANTIC_ENABLED do arquivo de ambiente (default do produto: true).';

notify pgrst, 'reload schema';

-- ---- O App da Meta sai do `.env` e vira linha da INSTALAÇÃO (migration 0257) ----
--
-- O App Secret e o verify token do webhook são do APP, e um App da Meta atende N
-- WABAs de N organizações: não há o que separar por tenant. Antes disto os dois
-- viviam no `.env` (SSH em quem instalou), e a partir do 2º número não havia como
-- configurar o app sem mexer no que já funcionava (issue #850, fatia F3).
--
-- Mesmo desenho de `platform_google_oauth` (0201): uma linha só, RLS ligada SEM
-- policies, `anon`/`authenticated` revogados e leitura/escrita pelo `service_role`
-- atrás do gate administrativo. O `revoke` é obrigatório porque o
-- `alter default privileges` do topo deste arquivo concede tabela nova a `anon` e
-- `authenticated`.
--
-- O `.env` NÃO é apagado: ele é o piso de rollback (código novo sobre banco que
-- ainda não aplicou esta migration) e a rota de verificação do webhook lê o banco
-- primeiro. As duas fontes não se misturam.
create table if not exists public.platform_meta_app (
  id smallint primary key default 1,
  app_secret_encrypted bytea,
  verify_token_encrypted bytea,
  verify_token_created_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint platform_meta_app_singleton check (id = 1)
);

comment on table public.platform_meta_app is
  'O App da Meta DESTA INSTALAÇÃO (singleton): App Secret que assina a entrega do webhook e verify token que responde ao handshake. Server-side only: RLS ligada sem policies e grants revogados de anon/authenticated — o PostgREST não a serve. Nenhum dos dois segredos volta ao browser; a tela devolve apenas se existem.';
comment on column public.platform_meta_app.app_secret_encrypted is
  'Cifrado por fn_encrypt_oauth (pgp_sym_encrypt/aes256). Nunca gravar em claro: sem a chave mestra o save recusa. Quem tem este valor assina uma entrega de webhook válida com dados inventados.';
comment on column public.platform_meta_app.verify_token_encrypted is
  'Cifrado por fn_encrypt_oauth. Gerado pelo SERVIDOR (32 bytes de CSPRNG) e exibido UMA vez: não há leitura que o devolva em claro — quem perde o valor usa a rotação da tela. Um token escolhido à mão ("deskcomm", o nome da empresa) é adivinhável, e quem o acerta passa a receber o tráfego do webhook.';
comment on column public.platform_meta_app.verify_token_created_at is
  'Quando o verify token em vigor nasceu. A tela mostra a data para quem acabou de rotacionar saber se o valor colado no painel da Meta é o novo.';

alter table public.platform_meta_app enable row level security;

revoke all on public.platform_meta_app from anon, authenticated;
grant select, insert, update on public.platform_meta_app to service_role;

drop trigger if exists trg_platform_meta_app_updated_at on public.platform_meta_app;
create trigger trg_platform_meta_app_updated_at
  before update on public.platform_meta_app
  for each row execute function public.fn_set_updated_at();
-- ---- a regra de automação guarda a CONFIGURAÇÃO do gatilho (migration 0268) ----
-- O gatilho de data do funil (#989) não nasce de evento: quem o emite é a
-- varredura `cron/lead-date-field-due`, e ela só sabe onde olhar se a regra
-- disser o funil, o campo de data e quantos dias antes (ou depois) avisar.
--
-- Vazio nos outros gatilhos, e `not null default '{}'` dispensa backfill: regra
-- que já existe nasce com o objeto vazio, e quem lê trata ausência e objeto
-- vazio do mesmo jeito.
alter table public.automation_rules
  add column if not exists trigger_config jsonb not null default '{}'::jsonb;

comment on column public.automation_rules.trigger_config is
  'Configuração do gatilho (issue #989). Vazio nos gatilhos que nascem de evento. No gatilho lead.date_field_due guarda {pipeline_id, campo, dias} — o campo de data pertence a UM funil, e sem essa dupla a varredura não sabe onde olhar.';

notify pgrst, 'reload schema';
-- 0311 · O webhook do NÚMERO, registrado pela própria instalação (issue #850, fatia F1).
--
-- ─── O que o usuário via ────────────────────────────────────────────────────
-- Conectar o canal oficial era metade do caminho: o canal ENVIAVA e não RECEBIA até
-- alguém entrar no painel da Meta, abrir a configuração do webhook, colar a URL de
-- callback e escolher os campos — por número. Quem não sabia disso (o produto é
-- self-host para quem NÃO programa) ficava com um canal que parece pronto e cujas
-- mensagens recebidas simplesmente não existem em lugar nenhum: nem erro, nem log.
--
-- ─── O que estas colunas guardam ────────────────────────────────────────────
-- O DESFECHO do registro automático, não a configuração: a URL que ficou registrada
-- (`meta_webhook_override_uri`), o motivo da última falha (`..._erro`) e quando foi
-- (`..._em`). São o que a tela lê para dizer "conectado, webhook pendente: <motivo>"
-- com botão de tentar de novo — em vez de dizer "conectado" e deixar a descoberta
-- para a primeira mensagem que nunca chega.
--
-- ─── Por que colunas, e não o `metadata` jsonb que já existe na tabela ──────
-- Porque a TELA consulta este estado a cada render e o desfecho tem três leitores
-- (GET do canal, POST de conexão, rota de re-registro): chave dentro de jsonb é
-- contrato que ninguém vê quebrar — o `metadata` da sessão é do ingest/roteamento, e
-- misturar os dois faz um `update` de lá apagar o desfecho daqui.
--
-- ─── Por que registrar DEPOIS de gravar a sessão ────────────────────────────
-- O GET de verificação da Meta chega no instante em que o override é registrado e
-- procura a sessão pelo `webhook_path_token`. Registrar antes de a linha existir
-- devolveria 404, e a Meta marcaria o webhook como inválido — pior que não registrar.
-- Ordem invertida = defeito, não preferência.
--
-- ─── Exposição: nenhuma nova ────────────────────────────────────────────────
-- A URL registrada contém o `webhook_path_token`, que JÁ vive nesta tabela
-- (`channel_sessions`, com `GRANT ALL` a anon/authenticated e RLS de isolamento por
-- organização desde as migrations 0106/0099). Não há coluna nova de segredo, não há
-- grant novo, não há policy nova: a coluna herda exatamente o acesso das vizinhas.
-- O que ela NÃO guarda é o token da Meta — esse continua só em
-- `meta_token_encrypted`, cifrado (fn_encrypt_oauth).
--
-- ─── O que NÃO entra aqui, de propósito ─────────────────────────────────────
-- * `message_template_status_update`: a Meta NÃO aceita override por número para este
--   tópico — ele continua indo para a URL do app (limite da plataforma, não escolha).
-- * Limpeza no arquivamento do canal e reaplicação na reconexão: é a fatia F1b, e
--   roda em cima destas mesmas colunas (`meta_webhook_override_uri` null = desfeito).
-- * Índice: as três colunas são lidas sempre pela chave primária da sessão.

alter table public.channel_sessions
  add column if not exists meta_webhook_override_uri text,
  add column if not exists meta_webhook_override_erro text,
  add column if not exists meta_webhook_override_em timestamptz;

comment on column public.channel_sessions.meta_webhook_override_uri is
  'URL de callback registrada na Meta para ESTE número (override por phone_number_id). Nulo = não registrado (ou desfeito). Contém o webhook_path_token, que já é desta tabela.';
comment on column public.channel_sessions.meta_webhook_override_erro is
  'Motivo da última falha ao registrar o webhook, como a Graph API devolveu. Não é falha da conexão: o canal envia normalmente; o que depende disto é a ENTREGA. Nulo = última tentativa deu certo.';
comment on column public.channel_sessions.meta_webhook_override_em is
  'Quando foi a última TENTATIVA de registrar (sucesso ou falha). A tela usa a data para o operador saber se o estado que ele vê é o de agora.';
-- ---- a resposta revisada para de segurar a Zona de perigo (migration 0273) ----
-- A FK inline da 0227 nasceu sem ação de exclusão (NO ACTION) e era a ÚNICA das
-- quatro que apontam para `public.messages(id)` fora do padrão `on delete set
-- null` das irmãs (v. 11337, 14759 e 19939). Resultado: numa organização que já
-- enviou uma resposta revisada, o PRIMEIRO delete da Zona de perigo
-- (`messages`, em `lib/settings/apagar-dados-operacionais.ts`) era recusado com
-- 23503 — `violates foreign key constraint "ai_reply_drafts_message_id_fkey"` —
-- e o reset morria sem apagar nada. `set null` e não `cascade`: existe caminho
-- legítimo que apaga mensagem por motivo alheio à resposta (dedup de eco,
-- exclusão de uma mensagem avulsa) e ali cascade apagaria o rascunho revisado —
-- histórico sumindo por causa de um ponteiro, o que a doutrina da irmã de 14759
-- proíbe. A Zona de perigo não precisa que o rascunho morra junto com a
-- mensagem: o cascade de `conversations` já leva os rascunhos da organização.
-- `message_id` é nullable, então não há default nem backfill.
alter table public.ai_reply_drafts
  drop constraint if exists ai_reply_drafts_message_id_fkey;

alter table public.ai_reply_drafts
  add constraint ai_reply_drafts_message_id_fkey
  foreign key (message_id) references public.messages(id) on delete set null;

notify pgrst, 'reload schema';

-- ---- a configuração da instalação cabe na tela (migration 0341) ----
-- 0341 — A configuração da INSTALAÇÃO sai do `.env` e passa a caber na tela.
--
-- ── O problema ───────────────────────────────────────────────────────────────
--
-- Trocar a chave de IA, o token do WAHA ou o remetente de e-mail exige SSH na
-- VPS, editar o `.env` e recriar os contêineres. Para o público do kit — quem
-- compra hospedagem e instala sozinho — isso é o mesmo que não ser configurável.
-- A marca (0155) e a credencial do Google (0201) já fizeram essa travessia; esta
-- migration generaliza o caminho para o resto da configuração.
--
-- ── Por que LINHAS e não COLUNAS ─────────────────────────────────────────────
--
-- `platform_branding` e `platform_settings` são singletons com uma coluna por
-- campo, e para 3 ou 4 campos isso é o certo. Aqui não serve, por duas razões
-- medidas:
--
--   1. ESCALA. São 42 chaves candidatas (27 migráveis + 15 knobs). Cifrada, cada
--      credencial ocupa quatro campos (ciphertext, iv, tag, last4) — a tabela
--      passaria de 150 colunas, e cada chave nova seria um ALTER.
--
--   2. O TUDO-OU-NADA. O cabeçalho de `lib/branding/instalacao.ts` documenta que
--      coluna nova em singleton é tudo-ou-nada por construção: código novo sobre
--      schema velho faz o PostgREST devolver `42703` para a LINHA INTEIRA, e a
--      marca toda cai no `.env`. Numa tabela de linhas esse modo de falha não
--      existe: chave que o banco ainda não tem é simplesmente linha ausente, e
--      linha ausente JÁ significa "usa o `.env`" — que é o mesmo desfecho, sem
--      derrubar as outras 41 no caminho.
--
-- ── Por que a cifra é da APLICAÇÃO e não do banco ────────────────────────────
--
-- O repositório tem DOIS padrões de cifra convivendo, e a escolha entre eles não
-- é estética:
--
--   • `fn_encrypt_oauth` (0201/0257) cifra no banco com `pgp_sym_encrypt`, e a
--     chave mora em `private.app_secrets`, semeada pelo kit.
--   • `lib/crypto/aes_gcm.ts` cifra na aplicação (AES-256-GCM), e a chave mora
--     só no `.env` (`AI_CRED_AES_KEY`). É o que já protege
--     `ai_provider_credentials`, com nove consumidores.
--
-- O `backup.sh` do kit roda `pg_dump` SEM filtrar schema, pela mesma conexão
-- privilegiada que semeia a chave — se a semeadura alcança `private.app_secrets`,
-- o dump também alcança. E o backup NÃO leva o `.env` (só banco + sessões do
-- WhatsApp). Com a cifra do banco, portanto, um arquivo de backup vazado entrega
-- a chave e o cofre juntos. Isso é tolerável para um segredo do Google; deixa de
-- ser quando o cofre guarda TODAS as credenciais da instalação.
--
-- Por isso esta tabela guarda o envelope AES-GCM cru (`ciphertext`/`iv`/`tag`) e
-- nenhuma função do banco sabe abri-lo. Backup vazado sem o `.env` é ruído.
--
-- ── `semeado_do_env` não é enfeite de proveniência ───────────────────────────
--
-- É o que impede o `.env` de desfazer uma escolha humana, e a regra vem inteira
-- de `precisaSemear` em `lib/branding/instalacao.ts`: a escrita pela tela zera o
-- campo, e linha com `semeado_do_env = false` NUNCA é semeada de novo. Sem isso,
-- o valor antigo do `.env` reescreveria no próximo boot o que a pessoa acabou de
-- digitar, e o campo pareceria não funcionar.
--
-- Apagar a linha é o "voltar ao padrão": sem linha, o resolvedor lê o `.env` de
-- novo e pode semear outra vez. Por isso `delete` entra no grant.
--
-- Sem dado tocado, sem backfill: tabela nova, vazia, e o resolvedor degrada para
-- o `.env` enquanto ela estiver assim.

create table if not exists public.platform_config (
  chave           text        primary key,
  valor           text,
  ciphertext      bytea,
  iv              bytea,
  tag             bytea,
  last4           text,
  eh_segredo      boolean     not null default false,
  semeado_do_env  boolean     not null default false,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  -- A chave É o nome da variável de ambiente, para que a correspondência
  -- banco ↔ `.env` seja literal e conferível por quem opera a VPS.
  constraint platform_config_chave_formato
    check (chave ~ '^[A-Z][A-Z0-9_]{2,63}$'),
  -- Segredo e knob são formas mutuamente exclusivas da mesma linha. Sem este
  -- XOR, uma linha poderia ter `valor` em claro E envelope cifrado — e o
  -- resolvedor teria de escolher, o que é como um segredo vaza em claro.
  constraint platform_config_forma_do_valor check (
    (eh_segredo
       and ciphertext is not null and iv is not null and tag is not null
       and valor is null)
    or
    (not eh_segredo
       and valor is not null
       and ciphertext is null and iv is null and tag is null)
  )
);

comment on table public.platform_config is
  'Configuração da INSTALAÇÃO editável pela tela (não do tenant): uma linha por variável, nomeada como a própria variável de ambiente. Linha ausente = usa o .env. Segredo guarda envelope AES-256-GCM cru (lib/crypto/aes_gcm.ts, chave em AI_CRED_AES_KEY, fora do banco de propósito — ver o cabeçalho da migration 0341); knob guarda texto. Lida/escrita só server-side por service_role. Ver lib/instalacao/config.ts.';

comment on column public.platform_config.semeado_do_env is
  'true = o valor veio do .env por semeadura automática e pode ser re-semeado. false = uma pessoa escreveu pela tela, e o .env NUNCA sobrescreve. Mesma regra de platform_branding.seeded_from_env (0155).';

comment on column public.platform_config.last4 is
  'Últimos 4 caracteres do segredo, para a tela identificar QUAL chave está lá sem nunca devolver o valor. Null para knob.';

-- ZERO POLICIES, DE PROPÓSITO — mesma decisão de `platform_branding` (0155) e
-- `platform_settings` (0253): esta linha não pertence a organização nenhuma,
-- então não há predicado de tenant que a isole. RLS ligada sem policy = ninguém
-- alcança pela REST; quem lê é o service_role, que a bypassa, e só do servidor.
alter table public.platform_config enable row level security;

-- As DUAS origens de grant, e tratar só uma deixa a tabela exposta com o gate
-- verde: (A) o `alter default privileges ... on tables to anon` do baseline
-- alcança TODA tabela criada depois dele — isto é, todo apêndice novo; (B) o
-- grant que o Postgres dá ao dono. O repositório já registra alguém que
-- conhecia a doutrina e errou exatamente aqui.
revoke all on public.platform_config from anon, authenticated;
grant select, insert, update, delete on public.platform_config to service_role;

drop trigger if exists trg_platform_config_touch on public.platform_config;
create trigger trg_platform_config_touch
  before update on public.platform_config
  for each row execute function public.fn_touch_updated_at();

notify pgrst, 'reload schema';

-- ---- CSV como material de conhecimento (migration 0310) ----
-- O bucket `ai-policy` (acima, migration 0014) tinha `allowed_mime_types`
-- fechado em PDF/Markdown/texto. O acervo de IA passou a aceitar CSV
-- (lib/ai/rag/extractors/csv.ts) — sem esta linha o Storage recusa o upload
-- ANTES de qualquer código da aplicação rodar, com erro sem relação nenhuma
-- com "extensão não suportada". `update`, não `insert ... on conflict`: o
-- bucket já existe em todo clone; é a MIME list que precisa alcançar quem
-- instalou antes desta mudança.
update storage.buckets
set allowed_mime_types = array['application/pdf', 'text/markdown', 'text/x-markdown', 'text/plain', 'text/csv']
where id = 'ai-policy';
-- ---- o recibo de idempotência ganha o estado "em curso" (migration 0321) ----
-- Issue #778, PR #1189 (@webtecnica). Reserva = `status_code` e `response_body`
-- nulos, gravada ANTES do efeito; recibo = os dois preenchidos. O `create table`
-- do corpo já nasce anulável (install); as duas primeiras linhas levam a
-- nulidade a quem JÁ tinha a tabela (update), onde o `create table if not
-- exists` é no-op. `drop not null` em coluna já anulável é no-op. O CHECK fecha
-- o meio-termo (um gravado e o outro não), que nenhum leitor sabe interpretar;
-- toda linha anterior tem as duas colunas preenchidas e passa sem backfill.
alter table public.idempotency_keys alter column status_code drop not null;
alter table public.idempotency_keys alter column response_body drop not null;
alter table public.idempotency_keys
  drop constraint if exists idempotency_keys_recibo_ou_reserva;
alter table public.idempotency_keys
  add constraint idempotency_keys_recibo_ou_reserva
  check ((status_code is null) = (response_body is null));

-- ---- destinos internos que o dono da instalação autoriza (migration 0326) ----
-- Decisão 22-d, #1004. null = nunca configurado pela tela (vale o .env);
-- '{}' = o dono esvaziou a lista. Idempotente; sem dado tocado.
alter table public.platform_settings
  add column if not exists internal_destinations text[];

comment on column public.platform_settings.internal_destinations is
  'IPv4 e faixas CIDR IPv4 que a INSTALAÇÃO pode alcançar mesmo sendo rede interna — só para destinos configurados pela instalação, nunca por uma organização (decisão 22-d, #1004). null = nunca configurado pela tela: vale IA_DESTINOS_INTERNOS_PERMITIDOS do .env. Array vazio = nada autorizado. Ver lib/automation/destinos-internos-autorizados.ts.';

notify pgrst, 'reload schema';

-- ---- marcador do contato normalizado, no dado que já estava gravado (migration 0335) ----
-- Issue #1224 (triagem do #1206), @webtecnica. A escrita passou a normalizar o
-- marcador do contato nos quatro caminhos (ficha, importação por CSV, API e
-- `crm_manage_tags`) pela MESMA função que o filtro usa para ler
-- (lib/contacts/tag-normalizada.ts) — sem isso, `?tag=vip` não encontra o contato
-- marcado como "VIP" e o chip do marcador não sai da ficha por remoção nenhuma.
-- Este apêndice é o backfill do dado ANTERIOR, e é idempotente por
-- `is distinct from`: aplicado numa VPS que já recebeu a migration 0335, nenhuma
-- linha é tocada (o arquivo é aplicado inteiro em quem instala, e de novo em
-- quem atualiza). A ordem é a mesma da aplicação — corta as pontas, minúsculas,
-- teto de 40 caracteres, descarta o vazio e tira o repetido — e a ordem de
-- primeira aparição é preservada (`with ordinality`) para a ficha do contato não
-- reembaralhar os marcadores de quem já os tinha.
update public.contacts c
   set tags = sub.normalizados
  from (
    select ct.id, array_agg(ct.tag order by ct.ord) as normalizados
      from (
        -- `c2.id` NA CHAVE: sem ele o `distinct on` é global e guarda UMA
        -- linha por marcador na TABELA INTEIRA — o segundo contato com "VIP"
        -- perde o marcador, e a deduplicação atravessa organizações. A
        -- consulta é válida, roda sem erro e sem aviso; o que denuncia é o
        -- dado. Reproduzido em Postgres 17.6: {VIP,Suporte} virava {suporte}.
        select distinct on (c2.id, left(lower(btrim(u.x)), 40))
               c2.id,
               left(lower(btrim(u.x)), 40) as tag,
               u.ord
          from public.contacts c2
          cross join lateral unnest(c2.tags) with ordinality as u(x, ord)
         where c2.tags is not null
           and left(lower(btrim(u.x)), 40) <> ''
         order by c2.id, left(lower(btrim(u.x)), 40), u.ord
      ) ct
     group by ct.id
  ) sub
 where c.id = sub.id
   and c.tags is distinct from sub.normalizados;

-- Marcador que era só espaço vira lista vazia: a sentença acima não alcança
-- essas linhas (a subconsulta descarta o vazio) e o contato ficaria com um
-- marcador invisível que nenhum filtro casa e nenhuma tela mostra.
update public.contacts c
   set tags = '{}'::text[]
 where c.tags is not null
   and cardinality(c.tags) > 0
   and c.tags is distinct from '{}'::text[]
   and not exists (
     select 1 from unnest(c.tags) as x where left(lower(btrim(x)), 40) <> ''
   );

notify pgrst, 'reload schema';

-- ---- banco de dados externo do agente (migrations 0372 e 0373) ----
--
-- Recorte do PR #1130, de @vgamkt. O cadastro da conexão da organização com um
-- PostgreSQL de OUTRO sistema (segundo CRM, ERP), que o agente consulta em
-- tempo real. A senha é cifrada pelo app (AES-256-GCM, `AI_CRED_AES_KEY`) e
-- nunca tem coluna em claro; a tela lê a view `_safe`, que omite as três
-- colunas cifradas.
--
-- Vem ANTES da reaplicação de módulos e das varreduras do fim do arquivo: é
-- tabela de organização nova, e é o que faz a PRIMEIRA aplicação deste arquivo
-- chegar ao mesmo conjunto de travas de suporte que a segunda.
--
-- Nenhuma função nova em `public` ⇒ nenhuma superfície `security definer` nova.
-- O bloco traz o estado FINAL das duas migrations (cadastro + limites por
-- conexão), porque o apêndice descreve onde o banco tem de chegar, não o
-- caminho.

create table if not exists public.external_db_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  label text not null,
  host text not null,
  port integer not null default 5432,
  database_name text not null,
  username text not null,
  password_encrypted bytea not null,
  password_iv bytea not null,
  password_tag bytea not null,
  ssl_mode text not null default 'require',
  enabled boolean not null default true,
  last_tested_at timestamptz,
  last_test_ok boolean,
  last_test_error text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint external_db_connections_label_uk unique (organization_id, label),
  constraint external_db_connections_port_valido check (port between 1 and 65535),
  constraint external_db_connections_ssl_conhecido
    check (ssl_mode in ('disable', 'prefer', 'require', 'verify-ca', 'verify-full'))
);

-- Os limites por conexão (0373). `if not exists` para o clone que já aplicou a
-- versão anterior deste bloco.
alter table public.external_db_connections
  add column if not exists max_rows integer not null default 200,
  add column if not exists max_filters integer not null default 20,
  add column if not exists max_response_bytes integer not null default 30000;

comment on table public.external_db_connections is
  'Conexão da organização com um PostgreSQL externo (outro CRM/sistema). A senha é cifrada com AES-GCM (AI_CRED_AES_KEY) e nunca é exposta: a tela lê external_db_connections_safe. O schema do banco externo não é espelhado — a introspecção é ao vivo.';
comment on column public.external_db_connections.password_encrypted is
  'Ciphertext AES-256-GCM. Par de password_iv (12 bytes) e password_tag (16 bytes). Sem AI_CRED_AES_KEY a leitura falha fechada.';
comment on column public.external_db_connections.ssl_mode is
  'Modo TLS da conexão pg. Default require: remoto sem TLS vaza credencial e dado.';
comment on column public.external_db_connections.last_test_error is
  'Erro do último teste de conexão, truncado e sem segredo. Superfície de falha lida pela tela.';
comment on column public.external_db_connections.max_rows is
  'Teto de linhas por consulta (grade e agente). Faixa 1..5000; default 200.';
comment on column public.external_db_connections.max_filters is
  'Teto de filtros por consulta do agente. Faixa 0..100; default 20.';
comment on column public.external_db_connections.max_response_bytes is
  'Teto de bytes da resposta devolvida ao modelo. Faixa 4096..1048576; default 30000.';

-- Doutrina de migrations, item 8: corrigir o dado ANTES da constraint. Num banco
-- novo não há linha; num clone onde alguém tenha escrito um teto fora da faixa
-- direto no SQL, o `update.sh` conserta em vez de quebrar.
update public.external_db_connections
   set max_rows = least(greatest(max_rows, 1), 5000)
 where max_rows not between 1 and 5000;
update public.external_db_connections
   set max_filters = least(greatest(max_filters, 0), 100)
 where max_filters not between 0 and 100;
update public.external_db_connections
   set max_response_bytes = least(greatest(max_response_bytes, 4096), 1048576)
 where max_response_bytes not between 4096 and 1048576;

alter table public.external_db_connections
  drop constraint if exists external_db_connections_max_rows_valido,
  drop constraint if exists external_db_connections_max_filters_valido,
  drop constraint if exists external_db_connections_max_response_bytes_valido;

alter table public.external_db_connections
  add constraint external_db_connections_max_rows_valido
    check (max_rows between 1 and 5000),
  add constraint external_db_connections_max_filters_valido
    check (max_filters between 0 and 100),
  add constraint external_db_connections_max_response_bytes_valido
    check (max_response_bytes between 4096 and 1048576);

create index if not exists external_db_connections_org_idx
  on public.external_db_connections (organization_id)
  where enabled;

alter table public.external_db_connections enable row level security;

drop policy if exists tenant_isolation_external_db_connections_select on public.external_db_connections;
create policy tenant_isolation_external_db_connections_select on public.external_db_connections
  for select
  using (organization_id in (select * from public.fn_user_org_ids()));

-- Leitura: qualquer membro (D2). Escrita: `admin` também na RLS — a mesma regra
-- na camada que sobrevive a uma rota nova.
drop policy if exists tenant_isolation_external_db_connections_modify on public.external_db_connections;
drop policy if exists tenant_isolation_external_db_connections_write on public.external_db_connections;
create policy tenant_isolation_external_db_connections_write on public.external_db_connections
  for all
  using (
    organization_id in (select * from public.fn_user_org_ids())
      and public.fn_role_at_least(organization_id, 'admin')
  )
  with check (
    organization_id in (select * from public.fn_user_org_ids())
      and public.fn_role_at_least(organization_id, 'admin')
  );

-- O ALTER DEFAULT PRIVILEGES deste baseline dá GRANT ALL em TABLES a `anon`:
-- toda tabela nova nasce exposta e precisa revogar por conta própria.
revoke all on public.external_db_connections from anon;

drop view if exists public.external_db_connections_safe;
create view public.external_db_connections_safe
  with (security_invoker = true)
  as
  select id, organization_id, label, host, port, database_name, username,
         ssl_mode, enabled, max_rows, max_filters, max_response_bytes,
         last_tested_at, last_test_ok, last_test_error,
         created_by, created_at, updated_at
  from public.external_db_connections;

revoke all on public.external_db_connections_safe from anon;
grant select on public.external_db_connections_safe to authenticated;

drop trigger if exists trg_external_db_connections_updated_at on public.external_db_connections;
create trigger trg_external_db_connections_updated_at
  before update on public.external_db_connections
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_external_db_connections_audit on public.external_db_connections;
create trigger trg_external_db_connections_audit
  after insert or update or delete on public.external_db_connections
  for each row execute function public.fn_audit_log_row();

-- ---- módulos instalados são reaplicados, depois de toda tabela do núcleo (migration 0340) ----
--
-- A provisionadora de cada módulo instalado roda de novo, sobre o núcleo já
-- atualizado. Falha de um módulo NÃO derruba este comando: ele marca o módulo
-- `suspenso` e a marca se confirma sozinha (o kit aplica sem transação única).
-- Vem ANTES das proteções e das travas, para que tabela recriada aqui passe por elas.
do $f$ begin perform public.fn_reaplicar_modulos_instalados(); end $f$;

-- ---- proteção de tabela de organização, depois de toda tabela (migration 0325) ----
--
-- Auto-curativa e no-op hoje (as 119 tabelas de organização deste baseline já
-- têm RLS ligada — medido, e cobrado por
-- tests/invariants/rls-completude-varredura.test.ts). Ela existe para o dia em
-- que um apêndice novo, ou a provisionadora de um módulo, criar tabela de
-- organização sem as proteções: a cura acontece no MESMO run em que o defeito
-- nasceria. Vem ANTES da chamada da 0274 de propósito — as travas do suporte
-- leem o privilégio de `authenticated` de cada tabela, então precisam ver a
-- tabela já com RLS e isolamento.
do $f$ begin perform public.fn_proteger_tabelas_de_organizacao(); end $f$;

-- ---- travas do modo somente leitura do suporte, depois de toda tabela (migration 0274) ----
--
-- ⚠️ ESTA CHAMADA É O ÚLTIMO BLOCO DO ARQUIVO. Tabela nova, coluna
-- `organization_id` nova, RLS ligada ou grant a `authenticated` entram ANTES
-- dela: é o que faz a primeira aplicação do arquivo chegar ao mesmo conjunto de
-- travas que a segunda. Vigiado, com o baseline aplicado UMA vez, por
-- tests/invariants/travas-de-suporte-cobrem-toda-tabela-na-instalacao.test.ts.
-- A definição da função está antes da varredura de anon.
do $f$ begin perform public.fn_aplicar_travas_de_suporte(); end $f$;

-- ---- Catálogo da DeepSeek (migration 0342) ----
--
-- O próximo provedor que a abertura de vocabulário da 0127 existia para
-- destravar: OpenAI-compatível e com desconto automático de prefixo de cache.
-- Ids e preços verificados no provedor (`GET /models`; docs oficiais em dólares
-- por 1M). Preço em CENTAVOS por milhão — entrada (cache miss) 14, saída 28; o
-- cache hit (0,28¢/1M) não cabe no integer do catálogo e é desconto de
-- cobrança, não preço de tabela. `ai_pricing` acompanha para o orçamento somar
-- com o mesmo número. Sem `is_default_for_provider`: a escolha cai no mais
-- barato com ferramentas, como na OpenRouter.
insert into public.ai_models
  (provider, model_id, display_name, description,
   input_price_per_million_cents, output_price_per_million_cents, supports_tools)
values
  ('deepseek', 'deepseek-flash',  'DeepSeek Flash',
   'O mais barato da DeepSeek, para atendimento de volume. Tem desconto automático do trecho repetido da conversa.',
   14, 28, true),
  ('deepseek', 'deepseek-v4-pro', 'DeepSeek V4 Pro',
   'O mais capaz da linha v4, para conversas que exigem raciocínio. Também desconta o trecho repetido da conversa.',
   44, 87, true)
on conflict (provider, model_id) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  input_price_per_million_cents = excluded.input_price_per_million_cents,
  output_price_per_million_cents = excluded.output_price_per_million_cents,
  supports_tools = excluded.supports_tools;

insert into public.ai_pricing
  (model, prompt_cents_per_million_tokens, completion_cents_per_million_tokens, notes)
values
  ('deepseek-flash',   14, 28, 'catálogo 0342 — cache hit 0,28¢/1M não cabe no catálogo'),
  ('deepseek-v4-pro',  44, 87, 'catálogo 0342 — cache hit 0,28¢/1M não cabe no catálogo')
on conflict (model) do update set
  prompt_cents_per_million_tokens = excluded.prompt_cents_per_million_tokens,
  completion_cents_per_million_tokens = excluded.completion_cents_per_million_tokens,
  notes = excluded.notes,
  superseded_at = null;

-- ---- menu lateral por EMPRESA (migration 0367, issue #1341) ----
--
-- `organizations.interface_settings` é a escolha da EMPRESA: o universo de portas
-- da instalação, com a mesma forma da escolha por vínculo da 0221. Entra aqui
-- para a instalação nova (e para a reaplicação do baseline) já nascer com a
-- coluna; a leitura resolve EMPRESA ∩ VÍNCULO ∩ papel, e o `default` deixa toda
-- organização que não mexer em nada exatamente como estava.
alter table public.organizations
  add column if not exists interface_settings jsonb not null
  default '{"preset":"completa"}'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.organizations'::regclass
       and conname = 'organizations_interface_settings_shape'
  ) then
    alter table public.organizations
      add constraint organizations_interface_settings_shape
      check (
        jsonb_typeof(interface_settings) = 'object'
        and interface_settings ? 'preset'
        and interface_settings->>'preset' in ('completa', 'simplificada')
        and (
          not interface_settings ? 'destinos'
          or (
            jsonb_typeof(interface_settings->'destinos') = 'array'
            and interface_settings->'destinos' <> '[]'::jsonb
          )
        )
      );
  end if;
end $$;

-- ---- módulo suspenso vira ERRO que o kit reporta (migration 0340) ----
--
-- Um comando SEPARADO da reaplicação, de propósito: se ela relançasse, a marca
-- de suspenso seria desfeita junto. Aqui o ERROR sai com texto que não casa com
-- a lista de erros benignos do update.sh, então a atualização não diz
-- "atualizado" com módulo fora do ar. Instalação nova não tem módulo: no-op.
do $f$ begin perform public.fn_conferir_modulos_instalados(); end $f$;
-- 0381 — registro do banco dedicado de cada organização
-- O control plane mantém apenas o registro cifrado; o tráfego de negócio
-- continua no banco compartilhado até a migração explícita do tenant.
create table if not exists public.organization_data_planes (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  status text not null default 'provisioning'
    check (status in ('provisioning', 'ready', 'degraded', 'retiring', 'failed')),
  connection_uri_encrypted bytea not null,
  connection_uri_iv bytea not null,
  connection_uri_tag bytea not null,
  connection_uri_last4 text not null check (char_length(connection_uri_last4) between 1 and 4),
  schema_version integer not null default 0 check (schema_version >= 0),
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
revoke all on public.organization_data_planes from anon, authenticated;
grant select, insert, update, delete on public.organization_data_planes to service_role;
create index if not exists organization_data_planes_status_idx
  on public.organization_data_planes(status);

create or replace function public.touch_organization_data_plane_updated_at()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
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

-- 0382 — credenciais cifradas do projeto Supabase dedicado para PostgREST.
alter table public.organization_data_planes
  add column if not exists api_url_encrypted bytea,
  add column if not exists api_url_iv bytea,
  add column if not exists api_url_tag bytea,
  add column if not exists api_key_encrypted bytea,
  add column if not exists api_key_iv bytea,
  add column if not exists api_key_tag bytea;

