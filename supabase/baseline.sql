Warning: truncated output (original token count: 421549)
... 637617 bytes omitted ...




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


CREATE TABLE IF NOT EXISTS "public"."lgpd_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "request_type" "text" NOT NULL,
    "source" "text" NOT NULL,
    "contact_id" "uuid",
    "external_customer_id" "text",
    "status" "text" DEFAULT 'received'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "due_at" timestamp with time zone NOT NULL,
    "completed_at" timestamp with time zone,
    "request_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "result" "jsonb",
    "error_message" "text",
    "cascaded_to" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "emergency" boolean DEFAULT false NOT NULL,
    "scope" "text" DEFAULT 'contact'::"text" NOT NULL,
    CONSTRAINT "lgpd_requests_request_type_check" CHECK (("request_type" = ANY (ARRAY['data_request'::"text", 'redact'::"text", 'store_redact'::"text"]))),
    CONSTRAINT "lgpd_requests_scope_check" CHECK (("scope" = ANY (ARRAY['contact'::"text", 'tenant'::"text"]))),
    CONSTRAINT "lgpd_requests_source_check" CHECK (("source" = ANY (ARRAY['nuvemshop'::"text", 'manual'::"text", 'api'::"text", 'support'::"text"]))),
    CONSTRAINT "lgpd_requests_status_check" CHECK (("status" = ANY (ARRAY['received'::"text", 'processing'::"text", 'completed'::"text", 'failed'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."lgpd_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."merge_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "candidates" "uuid"[] NOT NULL,
    "reason" "text" NOT NULL,
    "trigger_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "resolution" "jsonb",
    "resolved_by_user_id" "uuid",
    "resolved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "merge_queue_candidates_min2" CHECK (("array_length"("candidates", 1) >= 2)),
    CONSTRAINT "merge_queue_status_enum" CHECK (("status" = ANY (ARRAY['pending'::"text", 'resolved'::"text", 'discarded'::"text"])))
);


ALTER TABLE "public"."merge_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "channel_session_id" "uuid" NOT NULL,
    "contact_id" "uuid" NOT NULL,
    "external_id" "text",
    "type" "text" NOT NULL,
    "direction" "text" NOT NULL,
    "status" "text" DEFAULT 'received'::"text" NOT NULL,
    "ack" integer,
    "error_code" "text",
    "error_message" "text",
    "body" "text",
    "media_url" "text",
    "media_mime" "text",
    "media_size_bytes" bigint,
    "media_storage_path" "text",
    "sent_via" "text" DEFAULT 'crm'::"text" NOT NULL,
    "sent_by_user_id" "uuid",
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivered_at" timestamp with time zone,
    "read_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "activity_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "messages_direction_check" CHECK (("direction" = ANY (ARRAY['inbound'::"text", 'outbound'::"text"]))),
    CONSTRAINT "messages_sent_via_check" CHECK (("sent_via" = ANY (ARRAY['crm'::"text", 'external_device'::"text", 'automation'::"text", 'ai'::"text", 'user'::"text", 'system'::"text"]))),
    CONSTRAINT "messages_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'received'::"text", 'sending'::"text", 'sent'::"text", 'delivered'::"text", 'read'::"text", 'failed'::"text"]))),
    CONSTRAINT "messages_type_check" CHECK (("type" = ANY (ARRAY['text'::"text", 'image'::"text", 'video'::"text", 'audio'::"text", 'document'::"text", 'sticker'::"text", 'location'::"text", 'contact'::"text", 'reaction'::"text", 'system'::"text"])))
);


ALTER TABLE "public"."messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nuvemshop_products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "external_id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "price_cents" bigint NOT NULL,
    "available_qty" integer DEFAULT 0 NOT NULL,
    "url" "text",
    "image_url" "text",
    "rag_indexed_at" timestamp with time zone,
    "rag_chunk_count" integer DEFAULT 0 NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "last_updated_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "nuvemshop_products_price_cents_check" CHECK (("price_cents" >= 0))
);


ALTER TABLE "public"."nuvemshop_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "external_id" "text" NOT NULL,
    "external_provider" "text" NOT NULL,
    "customer_external_id" "text",
    "contact_id" "uuid",
    "status" "text" NOT NULL,
    "total_cents" bigint NOT NULL,
    "currency" character(3) DEFAULT 'BRL'::"bpchar" NOT NULL,
    "payment_method" "text",
    "fulfillment_status" "text",
    "tracking_code" "text",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "ordered_at" timestamp with time zone NOT NULL,
    "updated_at_remote" timestamp with time zone,
    "is_anonymized" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "orders_external_provider_check" CHECK (("external_provider" = ANY (ARRAY['nuvemshop'::"text", 'vtex'::"text", 'shopify'::"text"]))),
    CONSTRAINT "orders_fulfillment_status_check" CHECK (("fulfillment_status" = ANY (ARRAY['unpacked'::"text", 'packed'::"text", 'shipped'::"text", 'delivered'::"text"]))),
    CONSTRAINT "orders_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'paid'::"text", 'cancelled'::"text", 'fulfilled'::"text", 'shipped'::"text", 'delivered'::"text", 'refunded'::"text"]))),
    CONSTRAINT "orders_total_cents_check" CHECK (("total_cents" >= 0))
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "public"."citext" NOT NULL,
    "legal_name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "cnpj" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "timezone" "text" DEFAULT 'America/Sao_Paulo'::"text" NOT NULL,
    "locale" "text" DEFAULT 'pt-BR'::"text" NOT NULL,
    "rate_limit_rps" integer DEFAULT 100 NOT NULL,
    "ai_budget_cents" bigint,
    "media_retention_days" integer DEFAULT 365 NOT NULL,
    "settings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "dpo_email" "public"."citext",
    "privacy_policy_url" "text",
    "onboarded_at" timestamp with time zone,
    "suspended_at" timestamp with time zone,
    "redacted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "onboarding_state" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "suspended_reason" "text",
    "suspended_by" "uuid",
    CONSTRAINT "organizations_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'suspended'::"text", 'redacted'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."organizations" OWNER TO "postgres";


COMMENT ON TABLE "public"."organizations" IS 'Tenants do DeskcommCRM. Cada linha = 1 e-commerce cliente.';



COMMENT ON COLUMN "public"."organizations"."onboarded_at" IS 'Null = ainda em onboarding; populado quando step 5 completa';



COMMENT ON COLUMN "public"."organizations"."onboarding_state" IS 'Wizard state: { welcome?: {accepted_at, timezone, display_name}, whatsapp?: {session_id, status}, nuvemshop?: {connected_at, store_id}, ai?: {agent_id}, team?: {invites_sent} }';



CREATE TABLE IF NOT EXISTS "public"."platform_admins" (
    "user_id" "uuid" NOT NULL,
    "granted_by" "uuid" NOT NULL,
    "granted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "scope" "text" DEFAULT 'full'::"text" NOT NULL,
    "mfa_required" boolean DEFAULT true NOT NULL,
    "reason" "text" NOT NULL,
    "revoked_at" timestamp with time zone,
    "revoked_by" "uuid",
    "revoke_reason" "text",
    CONSTRAINT "platform_admins_scope_check" CHECK (("scope" = ANY (ARRAY['full'::"text", 'support_readonly'::"text"])))
);


ALTER TABLE "public"."platform_admins" OWNER TO "postgres";


COMMENT ON TABLE "public"."platform_admins" IS 'Super-admins que cruzam tenants. Modificacao SOMENTE via DBA + double-confirmation. T-04.';



CREATE TABLE IF NOT EXISTS "public"."storage_redaction_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "request_id" "uuid",
    "bucket" "text" NOT NULL,
    "object_path" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "error_message" "text",
    "enqueued_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp with time zone,
    CONSTRAINT "storage_redaction_queue_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'deleted'::"text", 'failed'::"text", 'skipped'::"text"])))
);


ALTER TABLE "public"."storage_redaction_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenant_integrations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "oauth_access_token_encrypted" "bytea" NOT NULL,
    "oauth_refresh_token_encrypted" "bytea",
    "scopes" "text"[] DEFAULT ARRAY[]::"text"[] NOT NULL,
    "expires_at" timestamp with time zone,
    "status" "text" DEFAULT 'connecting'::"text" NOT NULL,
    "status_reason" "text",
    "store_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "webhook_path_token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(24), 'hex'::"text") NOT NULL,
    "webhook_secret_encrypted" "bytea" NOT NULL,
    "webhook_subscriptions" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "last_sync_at" timestamp with time zone,
    "last_health_check_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "tenant_integrations_provider_check" CHECK (("provider" = ANY (ARRAY['nuvemshop'::"text", 'vtex'::"text", 'shopify'::"text"]))),
    CONSTRAINT "tenant_integrations_status_check" CHECK (("status" = ANY (ARRAY['connecting'::"text", 'healthy'::"text", 'token_expired'::"text", 'scope_missing'::"text", 'disconnected'::"text", 'rate_limited'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."tenant_integrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_organizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "organization_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "invited_by" "uuid",
    "invited_at" timestamp with time zone,
    "accepted_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_organizations_role_check" CHECK (("role" = ANY (ARRAY['viewer'::"text", 'agent'::"text", 'manager'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."user_organizations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."user_organizations"."role" IS '4 roles canônicos: viewer (1) < agent (2) < manager (3) < admin (4). Hierarquia.';



CREATE TABLE IF NOT EXISTS "public"."user_recovery_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "code_hash" "bytea" NOT NULL,
    "used_at" timestamp with time zone,
    "used_ip" "inet",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_recovery_codes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."webhook_events_log" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "organization_id" "uuid",
    "channel_session_id" "uuid",
    "provider" "text" DEFAULT 'waha'::"text" NOT NULL,
    "webhook_path_token" "text",
    "http_method" "text" DEFAULT 'POST'::"text" NOT NULL,
    "headers" "jsonb",
    "raw_body" "text" NOT NULL,
    "payload_parsed" "jsonb",
    "signature_header" "text",
    "valid_signature" boolean,
    "event_type" "text",
    "external_id" "text",
    "status" "text" DEFAULT 'received'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "error_message" "text",
    "processed_at" timestamp with time zone,
    "received_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "archived_at" timestamp with time zone,
    CONSTRAINT "webhook_events_log_provider_check" CHECK (("provider" = ANY (ARRAY['waha'::"text", 'nuvemshop'::"text", 'generic'::"text"]))),
    CONSTRAINT "webhook_events_log_status_check" CHECK (("status" = ANY (ARRAY['received'::"text", 'processed'::"text", 'error'::"text", 'dead'::"text"])))
);


ALTER TABLE "public"."webhook_events_log" OWNER TO "postgres";


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_pkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_pkey' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_unique_number' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_unique_number"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_unique_number" UNIQUE ("agent_id", "version_number");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agents_name_unique' AND conrelid = '"public"."ai_agents"'::regclass)
   AND to_regclass('"public"."ai_agents_name_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agents"
    ADD CONSTRAINT "ai_agents_name_unique" UNIQUE ("organization_id", "name");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agents_pkey' AND conrelid = '"public"."ai_agents"'::regclass)
   AND to_regclass('"public"."ai_agents_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agents"
    ADD CONSTRAINT "ai_agents_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_budgets_pkey' AND conrelid = '"public"."ai_budgets"'::regclass)
   AND to_regclass('"public"."ai_budgets_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_budgets"
    ADD CONSTRAINT "ai_budgets_pkey" PRIMARY KEY ("organization_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_chunks_pkey' AND conrelid = '"public"."ai_chunks"'::regclass)
   AND to_regclass('"public"."ai_chunks_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_chunks"
    ADD CONSTRAINT "ai_chunks_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_chunks_position_unique' AND conrelid = '"public"."ai_chunks"'::regclass)
   AND to_regclass('"public"."ai_chunks_position_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_chunks"
    ADD CONSTRAINT "ai_chunks_position_unique" UNIQUE ("knowledge_source_id", "kb_version_id", "position");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_faq_items_pkey' AND conrelid = '"public"."ai_faq_items"'::regclass)
   AND to_regclass('"public"."ai_faq_items_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_faq_items"
    ADD CONSTRAINT "ai_faq_items_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_invocations_pkey' AND conrelid = '"public"."ai_invocations"'::regclass)
   AND to_regclass('"public"."ai_invocations_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_invocations"
    ADD CONSTRAINT "ai_invocations_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_sources_pkey' AND conrelid = '"public"."ai_knowledge_sources"'::regclass)
   AND to_regclass('"public"."ai_knowledge_sources_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_sources"
    ADD CONSTRAINT "ai_knowledge_sources_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_versions_pkey' AND conrelid = '"public"."ai_knowledge_versions"'::regclass)
   AND to_regclass('"public"."ai_knowledge_versions_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_versions"
    ADD CONSTRAINT "ai_knowledge_versions_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_models_pkey' AND conrelid = '"public"."ai_models"'::regclass)
   AND to_regclass('"public"."ai_models_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_models"
    ADD CONSTRAINT "ai_models_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_models_unique' AND conrelid = '"public"."ai_models"'::regclass)
   AND to_regclass('"public"."ai_models_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_models"
    ADD CONSTRAINT "ai_models_unique" UNIQUE ("provider", "model_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_pricing_pkey' AND conrelid = '"public"."ai_pricing"'::regclass)
   AND to_regclass('"public"."ai_pricing_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_pricing"
    ADD CONSTRAINT "ai_pricing_pkey" PRIMARY KEY ("model");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_provider_credentials_pkey' AND conrelid = '"public"."ai_provider_credentials"'::regclass)
   AND to_regclass('"public"."ai_provider_credentials_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_provider_credentials"
    ADD CONSTRAINT "ai_provider_credentials_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_provider_credentials_unique' AND conrelid = '"public"."ai_provider_credentials"'::regclass)
   AND to_regclass('"public"."ai_provider_credentials_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_provider_credentials"
    ADD CONSTRAINT "ai_provider_credentials_unique" UNIQUE ("organization_id", "provider", "label");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_audit_log_pkey' AND conrelid = '"public"."api_audit_log"'::regclass)
   AND to_regclass('"public"."api_audit_log_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_audit_log"
    ADD CONSTRAINT "api_audit_log_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_tokens_organization_id_prefix_key' AND conrelid = '"public"."api_tokens"'::regclass)
   AND to_regclass('"public"."api_tokens_organization_id_prefix_key"') IS NULL THEN
ALTER TABLE ONLY "public"."api_tokens"
    ADD CONSTRAINT "api_tokens_organization_id_prefix_key" UNIQUE ("organization_id", "prefix");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_tokens_pkey' AND conrelid = '"public"."api_tokens"'::regclass)
   AND to_regclass('"public"."api_tokens_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_tokens"
    ADD CONSTRAINT "api_tokens_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_session_warmup_pkey' AND conrelid = '"public"."channel_session_warmup"'::regclass)
   AND to_regclass('"public"."channel_session_warmup_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_session_warmup"
    ADD CONSTRAINT "channel_session_warmup_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_sessions_phone_per_org_unique' AND conrelid = '"public"."channel_sessions"'::regclass)
   AND to_regclass('"public"."channel_sessions_phone_per_org_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_sessions"
    ADD CONSTRAINT "channel_sessions_phone_per_org_unique" UNIQUE ("organization_id", "phone_number") DEFERRABLE INITIALLY DEFERRED;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_sessions_pkey' AND conrelid = '"public"."channel_sessions"'::regclass)
   AND to_regclass('"public"."channel_sessions_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_sessions"
    ADD CONSTRAINT "channel_sessions_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_sessions_waha_session_name_unique' AND conrelid = '"public"."channel_sessions"'::regclass)
   AND to_regclass('"public"."channel_sessions_waha_session_name_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_sessions"
    ADD CONSTRAINT "channel_sessions_waha_session_name_unique" UNIQUE ("waha_session_name");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_sessions_webhook_path_token_unique' AND conrelid = '"public"."channel_sessions"'::regclass)
   AND to_regclass('"public"."channel_sessions_webhook_path_token_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_sessions"
    ADD CONSTRAINT "channel_sessions_webhook_path_token_unique" UNIQUE ("webhook_path_token");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'contacts_pkey' AND conrelid = '"public"."contacts"'::regclass)
   AND to_regclass('"public"."contacts_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_pkey' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_unique_per_contact_session' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_unique_per_contact_session"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_unique_per_contact_session" UNIQUE ("organization_id", "contact_id", "channel_session_id", "group_chat_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_activities_pkey' AND conrelid = '"public"."crm_lead_activities"'::regclass)
   AND to_regclass('"public"."crm_lead_activities_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_activities"
    ADD CONSTRAINT "crm_lead_activities_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_links_pkey' AND conrelid = '"public"."crm_lead_links"'::regclass)
   AND to_regclass('"public"."crm_lead_links_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_links"
    ADD CONSTRAINT "crm_lead_links_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_leads_pkey' AND conrelid = '"public"."crm_leads"'::regclass)
   AND to_regclass('"public"."crm_leads_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_leads"
    ADD CONSTRAINT "crm_leads_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_pipelines_pkey' AND conrelid = '"public"."crm_pipelines"'::regclass)
   AND to_regclass('"public"."crm_pipelines_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_pipelines"
    ADD CONSTRAINT "crm_pipelines_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_stages_pkey' AND conrelid = '"public"."crm_stages"'::regclass)
   AND to_regclass('"public"."crm_stages_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_stages"
    ADD CONSTRAINT "crm_stages_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'event_log_pkey' AND conrelid = '"public"."event_log"'::regclass)
   AND to_regclass('"public"."event_log_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."event_log"
    ADD CONSTRAINT "event_log_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'idempotency_keys_organization_id_key_endpoint_key' AND conrelid = '"public"."idempotency_keys"'::regclass)
   AND to_regclass('"public"."idempotency_keys_organization_id_key_endpoint_key"') IS NULL THEN
ALTER TABLE ONLY "public"."idempotency_keys"
    ADD CONSTRAINT "idempotency_keys_organization_id_key_endpoint_key" UNIQUE ("organization_id", "key", "endpoint");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'idempotency_keys_pkey' AND conrelid = '"public"."idempotency_keys"'::regclass)
   AND to_regclass('"public"."idempotency_keys_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."idempotency_keys"
    ADD CONSTRAINT "idempotency_keys_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'incidents_pkey' AND conrelid = '"public"."incidents"'::regclass)
   AND to_regclass('"public"."incidents_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."incidents"
    ADD CONSTRAINT "incidents_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'lgpd_requests_pkey' AND conrelid = '"public"."lgpd_requests"'::regclass)
   AND to_regclass('"public"."lgpd_requests_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."lgpd_requests"
    ADD CONSTRAINT "lgpd_requests_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'merge_queue_pkey' AND conrelid = '"public"."merge_queue"'::regclass)
   AND to_regclass('"public"."merge_queue_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."merge_queue"
    ADD CONSTRAINT "merge_queue_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_org_external_id_unique' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_org_external_id_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_org_external_id_unique" UNIQUE ("organization_id", "external_id") DEFERRABLE INITIALLY DEFERRED;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_pkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'nuvemshop_products_organization_id_external_id_key' AND conrelid = '"public"."nuvemshop_products"'::regclass)
   AND to_regclass('"public"."nuvemshop_products_organization_id_external_id_key"') IS NULL THEN
ALTER TABLE ONLY "public"."nuvemshop_products"
    ADD CONSTRAINT "nuvemshop_products_organization_id_external_id_key" UNIQUE ("organization_id", "external_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'nuvemshop_products_pkey' AND conrelid = '"public"."nuvemshop_products"'::regclass)
   AND to_regclass('"public"."nuvemshop_products_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."nuvemshop_products"
    ADD CONSTRAINT "nuvemshop_products_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'orders_organization_id_external_provider_external_id_key' AND conrelid = '"public"."orders"'::regclass)
   AND to_regclass('"public"."orders_organization_id_external_provider_external_id_key"') IS NULL THEN
ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_organization_id_external_provider_external_id_key" UNIQUE ("organization_id", "external_provider", "external_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'orders_pkey' AND conrelid = '"public"."orders"'::regclass)
   AND to_regclass('"public"."orders_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'organizations_cnpj_key' AND conrelid = '"public"."organizations"'::regclass)
   AND to_regclass('"public"."organizations_cnpj_key"') IS NULL THEN
ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_cnpj_key" UNIQUE ("cnpj");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'organizations_pkey' AND conrelid = '"public"."organizations"'::regclass)
   AND to_regclass('"public"."organizations_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'organizations_slug_key' AND conrelid = '"public"."organizations"'::regclass)
   AND to_regclass('"public"."organizations_slug_key"') IS NULL THEN
ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_slug_key" UNIQUE ("slug");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'platform_admins_pkey' AND conrelid = '"public"."platform_admins"'::regclass)
   AND to_regclass('"public"."platform_admins_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."platform_admins"
    ADD CONSTRAINT "platform_admins_pkey" PRIMARY KEY ("user_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'storage_redaction_queue_bucket_object_path_key' AND conrelid = '"public"."storage_redaction_queue"'::regclass)
   AND to_regclass('"public"."storage_redaction_queue_bucket_object_path_key"') IS NULL THEN
ALTER TABLE ONLY "public"."storage_redaction_queue"
    ADD CONSTRAINT "storage_redaction_queue_bucket_object_path_key" UNIQUE ("bucket", "object_path");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'storage_redaction_queue_pkey' AND conrelid = '"public"."storage_redaction_queue"'::regclass)
   AND to_regclass('"public"."storage_redaction_queue_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."storage_redaction_queue"
    ADD CONSTRAINT "storage_redaction_queue_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'tenant_integrations_organization_id_provider_key' AND conrelid = '"public"."tenant_integrations"'::regclass)
   AND to_regclass('"public"."tenant_integrations_organization_id_provider_key"') IS NULL THEN
ALTER TABLE ONLY "public"."tenant_integrations"
    ADD CONSTRAINT "tenant_integrations_organization_id_provider_key" UNIQUE ("organization_id", "provider");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'tenant_integrations_pkey' AND conrelid = '"public"."tenant_integrations"'::regclass)
   AND to_regclass('"public"."tenant_integrations_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."tenant_integrations"
    ADD CONSTRAINT "tenant_integrations_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_organizations_pkey' AND conrelid = '"public"."user_organizations"'::regclass)
   AND to_regclass('"public"."user_organizations_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."user_organizations"
    ADD CONSTRAINT "user_organizations_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_organizations_user_id_organization_id_key' AND conrelid = '"public"."user_organizations"'::regclass)
   AND to_regclass('"public"."user_organizations_user_id_organization_id_key"') IS NULL THEN
ALTER TABLE ONLY "public"."user_organizations"
    ADD CONSTRAINT "user_organizations_user_id_organization_id_key" UNIQUE ("user_id", "organization_id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_recovery_codes_pkey' AND conrelid = '"public"."user_recovery_codes"'::regclass)
   AND to_regclass('"public"."user_recovery_codes_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."user_recovery_codes"
    ADD CONSTRAINT "user_recovery_codes_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'warmup_session_day_unique' AND conrelid = '"public"."channel_session_warmup"'::regclass)
   AND to_regclass('"public"."warmup_session_day_unique"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_session_warmup"
    ADD CONSTRAINT "warmup_session_day_unique" UNIQUE ("channel_session_id", "day");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'webhook_events_log_pkey' AND conrelid = '"public"."webhook_events_log"'::regclass)
   AND to_regclass('"public"."webhook_events_log_pkey"') IS NULL THEN
ALTER TABLE ONLY "public"."webhook_events_log"
    ADD CONSTRAINT "webhook_events_log_pkey" PRIMARY KEY ("id");
END IF; END $baseline_guard$;



CREATE INDEX IF NOT EXISTS "ai_agent_runs_agent_idx" ON "public"."ai_agent_runs" USING "btree" ("agent_id", "started_at" DESC);



CREATE UNIQUE INDEX IF NOT EXISTS "ai_agent_runs_one_running_per_conv" ON "public"."ai_agent_runs" USING "btree" ("conversation_id") WHERE (("status" = 'running'::"text") AND ("is_dry_run" = false));



CREATE INDEX IF NOT EXISTS "ai_agent_runs_org_started_idx" ON "public"."ai_agent_runs" USING "btree" ("organization_id", "started_at" DESC);



CREATE INDEX IF NOT EXISTS "ai_agent_runs_status_idx" ON "public"."ai_agent_runs" USING "btree" ("status", "started_at") WHERE ("status" = ANY (ARRAY['pending'::"text", 'running'::"text"]));



CREATE INDEX IF NOT EXISTS "ai_agent_versions_agent_idx" ON "public"."ai_agent_versions" USING "btree" ("agent_id", "version_number" DESC);



CREATE UNIQUE INDEX IF NOT EXISTS "ai_agents_one_default_per_org" ON "public"."ai_agents" USING "btree" ("organization_id") WHERE "is_default";



CREATE INDEX IF NOT EXISTS "ai_agents_org_active_idx" ON "public"."ai_agents" USING "btree" ("organization_id") WHERE "is_active";



CREATE INDEX IF NOT EXISTS "ai_agents_published_idx" ON "public"."ai_agents" USING "btree" ("organization_id", "priority" DESC) WHERE (("published_version_id" IS NOT NULL) AND ("archived_at" IS NULL));



CREATE INDEX IF NOT EXISTS "ai_chunks_embedding_ivfflat_idx" ON "public"."ai_chunks" USING "ivfflat" ("embedding" "public"."vector_cosine_ops") WITH ("lists"='100');



CREATE INDEX IF NOT EXISTS "ai_chunks_metadata_gin_idx" ON "public"."ai_chunks" USING "gin" ("metadata");



CREATE INDEX IF NOT EXISTS "ai_chunks_org_kbv_idx" ON "public"."ai_chunks" USING "btree" ("organization_id", "kb_version_id");



CREATE INDEX IF NOT EXISTS "ai_chunks_source_idx" ON "public"."ai_chunks" USING "btree" ("knowledge_source_id");



CREATE INDEX IF NOT EXISTS "ai_faq_items_org_idx" ON "public"."ai_faq_items" USING "btree" ("organization_id");



CREATE INDEX IF NOT EXISTS "ai_faq_items_source_idx" ON "public"."ai_faq_items" USING "btree" ("knowledge_source_id", "position");



CREATE INDEX IF NOT EXISTS "ai_invocations_agent_kind_idx" ON "public"."ai_invocations" USING "btree" ("agent_id", "invocation_kind");



CREATE INDEX IF NOT EXISTS "ai_invocations_conversation_idx" ON "public"."ai_invocations" USING "btree" ("conversation_id") WHERE ("conversation_id" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "ai_invocations_org_created_idx" ON "public"."ai_invocations" USING "btree" ("organization_id", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "ai_knowledge_sources_agent_idx" ON "public"."ai_knowledge_sources" USING "btree" ("agent_id", "is_active");



CREATE UNIQUE INDEX IF NOT EXISTS "ai_models_one_default_per_provider" ON "public"."ai_models" USING "btree" ("provider") WHERE "is_default_for_provider";



CREATE INDEX IF NOT EXISTS "ai_provider_credentials_org_provider_idx" ON "public"."ai_provider_credentials" USING "btree" ("organization_id", "provider") WHERE "is_active";



CREATE INDEX IF NOT EXISTS "conversations_bot_silenced_idx" ON "public"."conversations" USING "btree" ("bot_silenced_until") WHERE ("bot_silenced_until" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "conversations_usable_rag_idx" ON "public"."conversations" USING "btree" ("organization_id", "usable_for_rag", "usable_for_rag_marked_at") WHERE ("usable_for_rag" = true);



CREATE INDEX IF NOT EXISTS "event_log_consumed_by_gin" ON "public"."event_log" USING "gin" ("consumed_by");



CREATE INDEX IF NOT EXISTS "event_log_dead_idx" ON "public"."event_log" USING "btree" ("organization_id", "created_at" DESC) WHERE ("status" = 'dead'::"text");



CREATE INDEX IF NOT EXISTS "event_log_entity_idx" ON "public"."event_log" USING "btree" ("entity_kind", "entity_id", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "event_log_org_type_idx" ON "public"."event_log" USING "btree" ("organization_id", "event_type", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "event_log_pending_idx" ON "public"."event_log" USING "btree" ("organization_id", "created_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX IF NOT EXISTS "idx_api_tokens_hash" ON "public"."api_tokens" USING "btree" ("token_hash") WHERE ("revoked_at" IS NULL);



CREATE INDEX IF NOT EXISTS "idx_api_tokens_org" ON "public"."api_tokens" USING "btree" ("organization_id") WHERE ("revoked_at" IS NULL);



CREATE INDEX IF NOT EXISTS "idx_audit_action_time" ON "public"."api_audit_log" USING "btree" ("action", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_audit_actor_time" ON "public"."api_audit_log" USING "btree" ("actor_user_id", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_audit_org_time" ON "public"."api_audit_log" USING "btree" ("organization_id", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_audit_request" ON "public"."api_audit_log" USING "btree" ("request_id");



CREATE INDEX IF NOT EXISTS "idx_audit_resource" ON "public"."api_audit_log" USING "btree" ("resource_type", "resource_id");



CREATE INDEX IF NOT EXISTS "idx_channel_sessions_health" ON "public"."channel_sessions" USING "btree" ("last_health_check_at") WHERE ("status" = 'WORKING'::"text");



CREATE INDEX IF NOT EXISTS "idx_channel_sessions_org_status" ON "public"."channel_sessions" USING "btree" ("organization_id", "status");



CREATE INDEX IF NOT EXISTS "idx_contacts_consent_gin" ON "public"."contacts" USING "gin" ("consent" "jsonb_path_ops");



CREATE INDEX IF NOT EXISTS "idx_contacts_org_blocked" ON "public"."contacts" USING "btree" ("organization_id") WHERE ("is_blocked" = true);



CREATE INDEX IF NOT EXISTS "idx_contacts_org_last_activity" ON "public"."contacts" USING "btree" ("organization_id", "last_activity_at" DESC NULLS LAST);



CREATE INDEX IF NOT EXISTS "idx_contacts_org_name_trgm" ON "public"."contacts" USING "gin" ("name" "public"."gin_trgm_ops");



CREATE INDEX IF NOT EXISTS "idx_contacts_tags_gin" ON "public"."contacts" USING "gin" ("tags");



CREATE INDEX IF NOT EXISTS "idx_conversations_assigned" ON "public"."conversations" USING "btree" ("assigned_to_user_id", "status") WHERE ("assigned_to_user_id" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "idx_conversations_open_unassigned" ON "public"."conversations" USING "btree" ("organization_id", "last_inbound_at" DESC) WHERE (("status" = 'open'::"text") AND ("assigned_to_user_id" IS NULL));



CREATE INDEX IF NOT EXISTS "idx_conversations_org_last_msg" ON "public"."conversations" USING "btree" ("organization_id", "last_message_at" DESC NULLS LAST);



CREATE INDEX IF NOT EXISTS "idx_crm_lead_links_org_target" ON "public"."crm_lead_links" USING "btree" ("organization_id", "target_kind", "target_id");



CREATE INDEX IF NOT EXISTS "idx_crm_leads_custom_fields_gin" ON "public"."crm_leads" USING "gin" ("custom_fields" "jsonb_path_ops");



CREATE INDEX IF NOT EXISTS "idx_crm_leads_org_contact" ON "public"."crm_leads" USING "btree" ("organization_id", "contact_id");



CREATE INDEX IF NOT EXISTS "idx_crm_leads_org_expected_close_overdue" ON "public"."crm_leads" USING "btree" ("organization_id", "expected_close_date") WHERE (("status" = 'open'::"text") AND ("expected_close_date" IS NOT NULL));



CREATE INDEX IF NOT EXISTS "idx_crm_leads_org_last_activity" ON "public"."crm_leads" USING "btree" ("organization_id", "last_activity_at" DESC NULLS LAST);



CREATE INDEX IF NOT EXISTS "idx_crm_leads_org_owner_status" ON "public"."crm_leads" USING "btree" ("organization_id", "owner_user_id", "status") WHERE ("status" = 'open'::"text");



CREATE INDEX IF NOT EXISTS "idx_crm_leads_org_pipeline_status" ON "public"."crm_leads" USING "btree" ("organization_id", "pipeline_id", "status");



CREATE INDEX IF NOT EXISTS "idx_crm_leads_org_stage_position" ON "public"."crm_leads" USING "btree" ("organization_id", "stage_id", "position_in_stage");



CREATE INDEX IF NOT EXISTS "idx_crm_leads_tags_gin" ON "public"."crm_leads" USING "gin" ("tags");



CREATE INDEX IF NOT EXISTS "idx_crm_pipelines_org_position" ON "public"."crm_pipelines" USING "btree" ("organization_id", "position") WHERE ("is_archived" = false);



CREATE INDEX IF NOT EXISTS "idx_crm_stages_pipeline_position" ON "public"."crm_stages" USING "btree" ("pipeline_id", "position") WHERE ("is_archived" = false);



CREATE INDEX IF NOT EXISTS "idx_idem_expiry" ON "public"."idempotency_keys" USING "btree" ("expires_at");



CREATE INDEX IF NOT EXISTS "idx_idem_lookup" ON "public"."idempotency_keys" USING "btree" ("organization_id", "key", "endpoint");



CREATE INDEX IF NOT EXISTS "idx_lead_activities_org_contact" ON "public"."crm_lead_activities" USING "btree" ("organization_id", "contact_id", "performed_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_lead_activities_org_lead_perf" ON "public"."crm_lead_activities" USING "btree" ("organization_id", "lead_id", "performed_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_lead_activities_org_type_perf" ON "public"."crm_lead_activities" USING "btree" ("organization_id", "type", "performed_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_lead_activities_payload_gin" ON "public"."crm_lead_activities" USING "gin" ("payload" "jsonb_path_ops");



CREATE INDEX IF NOT EXISTS "idx_merge_queue_org_status" ON "public"."merge_queue" USING "btree" ("organization_id", "status", "created_at");



CREATE INDEX IF NOT EXISTS "idx_messages_conversation_sent" ON "public"."messages" USING "btree" ("conversation_id", "sent_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_messages_external_lookup" ON "public"."messages" USING "btree" ("organization_id", "external_id") WHERE ("external_id" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "idx_messages_org_status_created" ON "public"."messages" USING "btree" ("organization_id", "status", "created_at") WHERE ("status" = ANY (ARRAY['sending'::"text", 'failed'::"text"]));



CREATE INDEX IF NOT EXISTS "idx_organizations_pending_onboarding" ON "public"."organizations" USING "btree" ("id") WHERE ("onboarded_at" IS NULL);



CREATE INDEX IF NOT EXISTS "idx_orgs_slug" ON "public"."organizations" USING "btree" ("slug");



CREATE INDEX IF NOT EXISTS "idx_orgs_status" ON "public"."organizations" USING "btree" ("status") WHERE ("status" = 'active'::"text");



CREATE UNIQUE INDEX IF NOT EXISTS "idx_recovery_unique" ON "public"."user_recovery_codes" USING "btree" ("user_id", "code_hash");



CREATE INDEX IF NOT EXISTS "idx_recovery_user" ON "public"."user_recovery_codes" USING "btree" ("user_id") WHERE ("used_at" IS NULL);



CREATE INDEX IF NOT EXISTS "idx_user_orgs_org_role" ON "public"."user_organizations" USING "btree" ("organization_id", "role") WHERE ("revoked_at" IS NULL);



CREATE INDEX IF NOT EXISTS "idx_user_orgs_user" ON "public"."user_organizations" USING "btree" ("user_id") WHERE ("revoked_at" IS NULL);



CREATE INDEX IF NOT EXISTS "idx_warmup_org_day" ON "public"."channel_session_warmup" USING "btree" ("organization_id", "day" DESC);



CREATE INDEX IF NOT EXISTS "idx_webhook_events_external_id" ON "public"."webhook_events_log" USING "btree" ("organization_id", "provider", "external_id") WHERE ("external_id" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "idx_webhook_events_org_received" ON "public"."webhook_events_log" USING "btree" ("organization_id", "received_at" DESC);



CREATE INDEX IF NOT EXISTS "idx_webhook_events_status_received" ON "public"."webhook_events_log" USING "btree" ("status", "received_at") WHERE ("status" = ANY (ARRAY['received'::"text", 'error'::"text"]));



CREATE INDEX IF NOT EXISTS "incidents_org_idx" ON "public"."incidents" USING "btree" ("organization_id", "created_at" DESC);



CREATE INDEX IF NOT EXISTS "incidents_severity_idx" ON "public"."incidents" USING "btree" ("severity", "status");



CREATE INDEX IF NOT EXISTS "incidents_status_idx" ON "public"."incidents" USING "btree" ("status", "created_at" DESC) WHERE ("status" <> 'resolved'::"text");



CREATE INDEX IF NOT EXISTS "lgpd_requests_contact_idx" ON "public"."lgpd_requests" USING "btree" ("contact_id") WHERE ("contact_id" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "lgpd_requests_emergency_idx" ON "public"."lgpd_requests" USING "btree" ("organization_id", "emergency", "due_at") WHERE ("emergency" = true);



CREATE INDEX IF NOT EXISTS "lgpd_requests_org_due_idx" ON "public"."lgpd_requests" USING "btree" ("organization_id", "due_at") WHERE ("status" = ANY (ARRAY['received'::"text", 'processing'::"text"]));



CREATE INDEX IF NOT EXISTS "lgpd_requests_org_status_idx" ON "public"."lgpd_requests" USING "btree" ("organization_id", "status");



CREATE INDEX IF NOT EXISTS "nuvemshop_products_org_idx" ON "public"."nuvemshop_products" USING "btree" ("organization_id");



CREATE INDEX IF NOT EXISTS "nuvemshop_products_rag_pending_idx" ON "public"."nuvemshop_products" USING "btree" ("organization_id") WHERE ("rag_indexed_at" IS NULL);



CREATE INDEX IF NOT EXISTS "nuvemshop_products_title_trgm" ON "public"."nuvemshop_products" USING "gin" ("title" "public"."gin_trgm_ops");



CREATE INDEX IF NOT EXISTS "orders_contact_idx" ON "public"."orders" USING "btree" ("contact_id") WHERE ("contact_id" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "orders_customer_external_idx" ON "public"."orders" USING "btree" ("organization_id", "external_provider", "customer_external_id");



CREATE INDEX IF NOT EXISTS "orders_org_ordered_idx" ON "public"."orders" USING "btree" ("organization_id", "ordered_at" DESC);



CREATE INDEX IF NOT EXISTS "orders_payload_gin" ON "public"."orders" USING "gin" ("payload" "jsonb_path_ops");



CREATE INDEX IF NOT EXISTS "orders_status_idx" ON "public"."orders" USING "btree" ("organization_id", "status");



CREATE INDEX IF NOT EXISTS "storage_redaction_queue_org_idx" ON "public"."storage_redaction_queue" USING "btree" ("organization_id");



CREATE INDEX IF NOT EXISTS "storage_redaction_queue_status_idx" ON "public"."storage_redaction_queue" USING "btree" ("status", "enqueued_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX IF NOT EXISTS "tenant_integrations_expires_idx" ON "public"."tenant_integrations" USING "btree" ("expires_at") WHERE ("expires_at" IS NOT NULL);



CREATE INDEX IF NOT EXISTS "tenant_integrations_org_idx" ON "public"."tenant_integrations" USING "btree" ("organization_id");



CREATE UNIQUE INDEX IF NOT EXISTS "tenant_integrations_path_token_idx" ON "public"."tenant_integrations" USING "btree" ("webhook_path_token");



CREATE INDEX IF NOT EXISTS "tenant_integrations_status_idx" ON "public"."tenant_integrations" USING "btree" ("status") WHERE ("status" = ANY (ARRAY['token_expired'::"text", 'error'::"text"]));



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_contacts_org_cpf" ON "public"."contacts" USING "btree" ("organization_id", "cpf_hash") WHERE (("cpf_hash" IS NOT NULL) AND ("is_merged_into" IS NULL));



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_contacts_org_email" ON "public"."contacts" USING "btree" ("organization_id", "email_normalized") WHERE (("email_normalized" IS NOT NULL) AND ("is_merged_into" IS NULL));



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_contacts_org_phone" ON "public"."contacts" USING "btree" ("organization_id", "phone_number") WHERE (("phone_number" IS NOT NULL) AND ("is_merged_into" IS NULL));



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_lead_links_lead_target_link" ON "public"."crm_lead_links" USING "btree" ("lead_id", "target_kind", "target_id", "link_kind");



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_leads_org_source_external" ON "public"."crm_leads" USING "btree" ("organization_id", "source", "external_id") WHERE ("external_id" IS NOT NULL);



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_pipelines_org_default" ON "public"."crm_pipelines" USING "btree" ("organization_id") WHERE ("is_default" = true);



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_pipelines_org_slug" ON "public"."crm_pipelines" USING "btree" ("organization_id", "slug");



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_stages_pipeline_lost" ON "public"."crm_stages" USING "btree" ("pipeline_id") WHERE (("is_lost" = true) AND ("is_archived" = false));



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_stages_pipeline_slug" ON "public"."crm_stages" USING "btree" ("pipeline_id", "slug");



CREATE UNIQUE INDEX IF NOT EXISTS "uniq_crm_stages_pipeline_won" ON "public"."crm_stages" USING "btree" ("pipeline_id") WHERE (("is_won" = true) AND ("is_archived" = false));



CREATE INDEX IF NOT EXISTS "webhook_events_log_dlq_idx" ON "public"."webhook_events_log" USING "btree" ("organization_id", "provider") WHERE ("status" = 'dead'::"text");



CREATE INDEX IF NOT EXISTS "webhook_events_log_lgpd_idx" ON "public"."webhook_events_log" USING "btree" ("organization_id", "provider", "event_type", "received_at" DESC) WHERE ("event_type" = ANY (ARRAY['customer/redact'::"text", 'customer/data_request'::"text", 'store/redact'::"text"]));



CREATE OR REPLACE TRIGGER "ai_faq_items_updated_at" BEFORE UPDATE ON "public"."ai_faq_items" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "incidents_updated_at" BEFORE UPDATE ON "public"."incidents" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ai_agent_runs_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."ai_agent_runs" FOR EACH ROW EXECUTE FUNCTION "public"."fn_audit_log_row"();



CREATE OR REPLACE TRIGGER "trg_ai_agent_versions_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."ai_agent_versions" FOR EACH ROW EXECUTE FUNCTION "public"."fn_audit_log_row"();



CREATE OR REPLACE TRIGGER "trg_ai_agents_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."ai_agents" FOR EACH ROW EXECUTE FUNCTION "public"."fn_audit_log_row"();



CREATE OR REPLACE TRIGGER "trg_ai_agents_updated_at" BEFORE UPDATE ON "public"."ai_agents" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ai_budgets_updated_at" BEFORE UPDATE ON "public"."ai_budgets" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ai_invocations_budget" AFTER INSERT ON "public"."ai_invocations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_update_budget_consumption"();



CREATE OR REPLACE TRIGGER "trg_ai_knowledge_sources_updated_at" BEFORE UPDATE ON "public"."ai_knowledge_sources" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_ai_provider_credentials_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."ai_provider_credentials" FOR EACH ROW EXECUTE FUNCTION "public"."fn_audit_log_row"();



CREATE OR REPLACE TRIGGER "trg_api_tokens_touch" BEFORE UPDATE ON "public"."api_tokens" FOR EACH ROW EXECUTE FUNCTION "public"."fn_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_channel_sessions_status_audit" AFTER UPDATE OF "status" ON "public"."channel_sessions" FOR EACH ROW WHEN (("old"."status" IS DISTINCT FROM "new"."status")) EXECUTE FUNCTION "public"."fn_emit_channel_session_status_changed"();



CREATE OR REPLACE TRIGGER "trg_channel_sessions_updated_at" BEFORE UPDATE ON "public"."channel_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_contacts_updated_at" BEFORE UPDATE ON "public"."contacts" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_conversations_updated_at" BEFORE UPDATE ON "public"."conversations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_lead_close_on_stage" BEFORE INSERT OR UPDATE OF "stage_id" ON "public"."crm_leads" FOR EACH ROW EXECUTE FUNCTION "public"."fn_crm_lead_close_on_stage"();



CREATE OR REPLACE TRIGGER "trg_crm_leads_updated_at" BEFORE UPDATE ON "public"."crm_leads" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_pipelines_updated_at" BEFORE UPDATE ON "public"."crm_pipelines" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_stages_updated_at" BEFORE UPDATE ON "public"."crm_stages" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_emit_event_on_lead_change" AFTER INSERT OR UPDATE ON "public"."crm_leads" FOR EACH ROW EXECUTE FUNCTION "public"."fn_emit_event_on_lead_change"();



CREATE OR REPLACE TRIGGER "trg_event_log_touch" BEFORE UPDATE ON "public"."event_log" FOR EACH ROW EXECUTE FUNCTION "public"."fn_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_lgpd_requests_updated_at" BEFORE UPDATE ON "public"."lgpd_requests" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_messages_emit_event" AFTER INSERT ON "public"."messages" FOR EACH ROW EXECUTE FUNCTION "public"."fn_emit_message_event"();



CREATE OR REPLACE TRIGGER "trg_messages_updated_at" BEFORE UPDATE ON "public"."messages" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_nuvemshop_products_updated_at" BEFORE UPDATE ON "public"."nuvemshop_products" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_orders_updated_at" BEFORE UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_organizations_touch" BEFORE UPDATE ON "public"."organizations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_seed_default_pipeline_for_org" AFTER INSERT ON "public"."organizations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_seed_default_pipeline_for_org"();



CREATE OR REPLACE TRIGGER "trg_tenant_integrations_updated_at" BEFORE UPDATE ON "public"."tenant_integrations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_update_last_activity_at" AFTER INSERT ON "public"."crm_lead_activities" FOR EACH ROW EXECUTE FUNCTION "public"."fn_update_last_activity_at"();



CREATE OR REPLACE TRIGGER "trg_user_orgs_touch" BEFORE UPDATE ON "public"."user_organizations" FOR EACH ROW EXECUTE FUNCTION "public"."fn_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_validate_activity_lead_org" BEFORE INSERT ON "public"."crm_lead_activities" FOR EACH ROW EXECUTE FUNCTION "public"."fn_validate_activity_lead_org"();



CREATE OR REPLACE TRIGGER "trg_validate_lost_reason_required" BEFORE INSERT OR UPDATE OF "status", "lost_reason" ON "public"."crm_leads" FOR EACH ROW EXECUTE FUNCTION "public"."fn_validate_lost_reason_required"();



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_agent_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_agent_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."ai_agents"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_agent_version_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_agent_version_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_agent_version_id_fkey" FOREIGN KEY ("agent_version_id") REFERENCES "public"."ai_agent_versions"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_channel_session_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_channel_session_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_channel_session_id_fkey" FOREIGN KEY ("channel_session_id") REFERENCES "public"."channel_sessions"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_contact_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_conversation_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_conversation_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."conversations"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_inbound_message_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_inbound_message_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_inbound_message_id_fkey" FOREIGN KEY ("inbound_message_id") REFERENCES "public"."messages"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_organization_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_runs_outbound_message_id_fkey' AND conrelid = '"public"."ai_agent_runs"'::regclass)
   AND to_regclass('"public"."ai_agent_runs_outbound_message_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_runs"
    ADD CONSTRAINT "ai_agent_runs_outbound_message_id_fkey" FOREIGN KEY ("outbound_message_id") REFERENCES "public"."messages"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_agent_id_fkey' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_agent_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."ai_agents"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_channel_session_id_fkey' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_channel_session_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_channel_session_id_fkey" FOREIGN KEY ("channel_session_id") REFERENCES "public"."channel_sessions"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_created_by_fkey' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_created_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_credential_id_fkey' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_credential_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_credential_id_fkey" FOREIGN KEY ("credential_id") REFERENCES "public"."ai_provider_credentials"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agent_versions_organization_id_fkey' AND conrelid = '"public"."ai_agent_versions"'::regclass)
   AND to_regclass('"public"."ai_agent_versions_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agent_versions"
    ADD CONSTRAINT "ai_agent_versions_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agents_created_by_fkey' AND conrelid = '"public"."ai_agents"'::regclass)
   AND to_regclass('"public"."ai_agents_created_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agents"
    ADD CONSTRAINT "ai_agents_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agents_organization_id_fkey' AND conrelid = '"public"."ai_agents"'::regclass)
   AND to_regclass('"public"."ai_agents_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agents"
    ADD CONSTRAINT "ai_agents_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_agents_published_version_id_fkey' AND conrelid = '"public"."ai_agents"'::regclass)
   AND to_regclass('"public"."ai_agents_published_version_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_agents"
    ADD CONSTRAINT "ai_agents_published_version_id_fkey" FOREIGN KEY ("published_version_id") REFERENCES "public"."ai_agent_versions"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_budgets_organization_id_fkey' AND conrelid = '"public"."ai_budgets"'::regclass)
   AND to_regclass('"public"."ai_budgets_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_budgets"
    ADD CONSTRAINT "ai_budgets_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_chunks_knowledge_source_id_fkey' AND conrelid = '"public"."ai_chunks"'::regclass)
   AND to_regclass('"public"."ai_chunks_knowledge_source_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_chunks"
    ADD CONSTRAINT "ai_chunks_knowledge_source_id_fkey" FOREIGN KEY ("knowledge_source_id") REFERENCES "public"."ai_knowledge_sources"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_chunks_organization_id_fkey' AND conrelid = '"public"."ai_chunks"'::regclass)
   AND to_regclass('"public"."ai_chunks_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_chunks"
    ADD CONSTRAINT "ai_chunks_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_faq_items_knowledge_source_id_fkey' AND conrelid = '"public"."ai_faq_items"'::regclass)
   AND to_regclass('"public"."ai_faq_items_knowledge_source_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_faq_items"
    ADD CONSTRAINT "ai_faq_items_knowledge_source_id_fkey" FOREIGN KEY ("knowledge_source_id") REFERENCES "public"."ai_knowledge_sources"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_faq_items_organization_id_fkey' AND conrelid = '"public"."ai_faq_items"'::regclass)
   AND to_regclass('"public"."ai_faq_items_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_faq_items"
    ADD CONSTRAINT "ai_faq_items_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_invocations_agent_id_fkey' AND conrelid = '"public"."ai_invocations"'::regclass)
   AND to_regclass('"public"."ai_invocations_agent_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_invocations"
    ADD CONSTRAINT "ai_invocations_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."ai_agents"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_invocations_conversation_id_fkey' AND conrelid = '"public"."ai_invocations"'::regclass)
   AND to_regclass('"public"."ai_invocations_conversation_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_invocations"
    ADD CONSTRAINT "ai_invocations_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."conversations"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_invocations_message_id_fkey' AND conrelid = '"public"."ai_invocations"'::regclass)
   AND to_regclass('"public"."ai_invocations_message_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_invocations"
    ADD CONSTRAINT "ai_invocations_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."messages"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_invocations_organization_id_fkey' AND conrelid = '"public"."ai_invocations"'::regclass)
   AND to_regclass('"public"."ai_invocations_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_invocations"
    ADD CONSTRAINT "ai_invocations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_sources_agent_id_fkey' AND conrelid = '"public"."ai_knowledge_sources"'::regclass)
   AND to_regclass('"public"."ai_knowledge_sources_agent_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_sources"
    ADD CONSTRAINT "ai_knowledge_sources_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."ai_agents"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_sources_organization_id_fkey' AND conrelid = '"public"."ai_knowledge_sources"'::regclass)
   AND to_regclass('"public"."ai_knowledge_sources_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_sources"
    ADD CONSTRAINT "ai_knowledge_sources_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_versions_activated_by_fkey' AND conrelid = '"public"."ai_knowledge_versions"'::regclass)
   AND to_regclass('"public"."ai_knowledge_versions_activated_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_versions"
    ADD CONSTRAINT "ai_knowledge_versions_activated_by_fkey" FOREIGN KEY ("activated_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_versions_agent_id_fkey' AND conrelid = '"public"."ai_knowledge_versions"'::regclass)
   AND to_regclass('"public"."ai_knowledge_versions_agent_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_versions"
    ADD CONSTRAINT "ai_knowledge_versions_agent_id_fkey" FOREIGN KEY ("agent_id") REFERENCES "public"."ai_agents"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_knowledge_versions_organization_id_fkey' AND conrelid = '"public"."ai_knowledge_versions"'::regclass)
   AND to_regclass('"public"."ai_knowledge_versions_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_knowledge_versions"
    ADD CONSTRAINT "ai_knowledge_versions_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_provider_credentials_created_by_fkey' AND conrelid = '"public"."ai_provider_credentials"'::regclass)
   AND to_regclass('"public"."ai_provider_credentials_created_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_provider_credentials"
    ADD CONSTRAINT "ai_provider_credentials_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'ai_provider_credentials_organization_id_fkey' AND conrelid = '"public"."ai_provider_credentials"'::regclass)
   AND to_regclass('"public"."ai_provider_credentials_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."ai_provider_credentials"
    ADD CONSTRAINT "ai_provider_credentials_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_audit_log_actor_api_token_id_fkey' AND conrelid = '"public"."api_audit_log"'::regclass)
   AND to_regclass('"public"."api_audit_log_actor_api_token_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_audit_log"
    ADD CONSTRAINT "api_audit_log_actor_api_token_id_fkey" FOREIGN KEY ("actor_api_token_id") REFERENCES "public"."api_tokens"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_audit_log_actor_user_id_fkey' AND conrelid = '"public"."api_audit_log"'::regclass)
   AND to_regclass('"public"."api_audit_log_actor_user_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_audit_log"
    ADD CONSTRAINT "api_audit_log_actor_user_id_fkey" FOREIGN KEY ("actor_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_audit_log_organization_id_fkey' AND conrelid = '"public"."api_audit_log"'::regclass)
   AND to_regclass('"public"."api_audit_log_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_audit_log"
    ADD CONSTRAINT "api_audit_log_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_tokens_created_by_fkey' AND conrelid = '"public"."api_tokens"'::regclass)
   AND to_regclass('"public"."api_tokens_created_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_tokens"
    ADD CONSTRAINT "api_tokens_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_tokens_organization_id_fkey' AND conrelid = '"public"."api_tokens"'::regclass)
   AND to_regclass('"public"."api_tokens_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_tokens"
    ADD CONSTRAINT "api_tokens_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'api_tokens_revoked_by_fkey' AND conrelid = '"public"."api_tokens"'::regclass)
   AND to_regclass('"public"."api_tokens_revoked_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."api_tokens"
    ADD CONSTRAINT "api_tokens_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_session_warmup_channel_session_id_fkey' AND conrelid = '"public"."channel_session_warmup"'::regclass)
   AND to_regclass('"public"."channel_session_warmup_channel_session_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_session_warmup"
    ADD CONSTRAINT "channel_session_warmup_channel_session_id_fkey" FOREIGN KEY ("channel_session_id") REFERENCES "public"."channel_sessions"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_session_warmup_organization_id_fkey' AND conrelid = '"public"."channel_session_warmup"'::regclass)
   AND to_regclass('"public"."channel_session_warmup_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_session_warmup"
    ADD CONSTRAINT "channel_session_warmup_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_sessions_created_by_fkey' AND conrelid = '"public"."channel_sessions"'::regclass)
   AND to_regclass('"public"."channel_sessions_created_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_sessions"
    ADD CONSTRAINT "channel_sessions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'channel_sessions_organization_id_fkey' AND conrelid = '"public"."channel_sessions"'::regclass)
   AND to_regclass('"public"."channel_sessions_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."channel_sessions"
    ADD CONSTRAINT "channel_sessions_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'contacts_is_merged_into_fkey' AND conrelid = '"public"."contacts"'::regclass)
   AND to_regclass('"public"."contacts_is_merged_into_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_is_merged_into_fkey" FOREIGN KEY ("is_merged_into") REFERENCES "public"."contacts"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'contacts_organization_id_fkey' AND conrelid = '"public"."contacts"'::regclass)
   AND to_regclass('"public"."contacts_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."contacts"
    ADD CONSTRAINT "contacts_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_assigned_to_user_id_fkey' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_assigned_to_user_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_assigned_to_user_id_fkey" FOREIGN KEY ("assigned_to_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_channel_session_id_fkey' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_channel_session_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_channel_session_id_fkey" FOREIGN KEY ("channel_session_id") REFERENCES "public"."channel_sessions"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_contact_id_fkey' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_organization_id_fkey' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'conversations_usable_for_rag_marked_by_fkey' AND conrelid = '"public"."conversations"'::regclass)
   AND to_regclass('"public"."conversations_usable_for_rag_marked_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."conversations"
    ADD CONSTRAINT "conversations_usable_for_rag_marked_by_fkey" FOREIGN KEY ("usable_for_rag_marked_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_activities_contact_id_fkey' AND conrelid = '"public"."crm_lead_activities"'::regclass)
   AND to_regclass('"public"."crm_lead_activities_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_activities"
    ADD CONSTRAINT "crm_lead_activities_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_activities_lead_id_fkey' AND conrelid = '"public"."crm_lead_activities"'::regclass)
   AND to_regclass('"public"."crm_lead_activities_lead_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_activities"
    ADD CONSTRAINT "crm_lead_activities_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."crm_leads"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_activities_organization_id_fkey' AND conrelid = '"public"."crm_lead_activities"'::regclass)
   AND to_regclass('"public"."crm_lead_activities_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_activities"
    ADD CONSTRAINT "crm_lead_activities_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_links_lead_id_fkey' AND conrelid = '"public"."crm_lead_links"'::regclass)
   AND to_regclass('"public"."crm_lead_links_lead_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_links"
    ADD CONSTRAINT "crm_lead_links_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."crm_leads"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_lead_links_organization_id_fkey' AND conrelid = '"public"."crm_lead_links"'::regclass)
   AND to_regclass('"public"."crm_lead_links_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_lead_links"
    ADD CONSTRAINT "crm_lead_links_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_leads_contact_id_fkey' AND conrelid = '"public"."crm_leads"'::regclass)
   AND to_regclass('"public"."crm_leads_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_leads"
    ADD CONSTRAINT "crm_leads_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_leads_organization_id_fkey' AND conrelid = '"public"."crm_leads"'::regclass)
   AND to_regclass('"public"."crm_leads_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_leads"
    ADD CONSTRAINT "crm_leads_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_leads_pipeline_id_fkey' AND conrelid = '"public"."crm_leads"'::regclass)
   AND to_regclass('"public"."crm_leads_pipeline_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_leads"
    ADD CONSTRAINT "crm_leads_pipeline_id_fkey" FOREIGN KEY ("pipeline_id") REFERENCES "public"."crm_pipelines"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_leads_stage_id_fkey' AND conrelid = '"public"."crm_leads"'::regclass)
   AND to_regclass('"public"."crm_leads_stage_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_leads"
    ADD CONSTRAINT "crm_leads_stage_id_fkey" FOREIGN KEY ("stage_id") REFERENCES "public"."crm_stages"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_pipelines_organization_id_fkey' AND conrelid = '"public"."crm_pipelines"'::regclass)
   AND to_regclass('"public"."crm_pipelines_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_pipelines"
    ADD CONSTRAINT "crm_pipelines_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_stages_organization_id_fkey' AND conrelid = '"public"."crm_stages"'::regclass)
   AND to_regclass('"public"."crm_stages_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_stages"
    ADD CONSTRAINT "crm_stages_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'crm_stages_pipeline_id_fkey' AND conrelid = '"public"."crm_stages"'::regclass)
   AND to_regclass('"public"."crm_stages_pipeline_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."crm_stages"
    ADD CONSTRAINT "crm_stages_pipeline_id_fkey" FOREIGN KEY ("pipeline_id") REFERENCES "public"."crm_pipelines"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'event_log_organization_id_fkey' AND conrelid = '"public"."event_log"'::regclass)
   AND to_regclass('"public"."event_log_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."event_log"
    ADD CONSTRAINT "event_log_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'idempotency_keys_organization_id_fkey' AND conrelid = '"public"."idempotency_keys"'::regclass)
   AND to_regclass('"public"."idempotency_keys_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."idempotency_keys"
    ADD CONSTRAINT "idempotency_keys_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'incidents_acknowledged_by_fkey' AND conrelid = '"public"."incidents"'::regclass)
   AND to_regclass('"public"."incidents_acknowledged_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."incidents"
    ADD CONSTRAINT "incidents_acknowledged_by_fkey" FOREIGN KEY ("acknowledged_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'incidents_organization_id_fkey' AND conrelid = '"public"."incidents"'::regclass)
   AND to_regclass('"public"."incidents_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."incidents"
    ADD CONSTRAINT "incidents_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'incidents_resolved_by_fkey' AND conrelid = '"public"."incidents"'::regclass)
   AND to_regclass('"public"."incidents_resolved_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."incidents"
    ADD CONSTRAINT "incidents_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'lgpd_requests_contact_id_fkey' AND conrelid = '"public"."lgpd_requests"'::regclass)
   AND to_regclass('"public"."lgpd_requests_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."lgpd_requests"
    ADD CONSTRAINT "lgpd_requests_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'lgpd_requests_organization_id_fkey' AND conrelid = '"public"."lgpd_requests"'::regclass)
   AND to_regclass('"public"."lgpd_requests_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."lgpd_requests"
    ADD CONSTRAINT "lgpd_requests_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'merge_queue_organization_id_fkey' AND conrelid = '"public"."merge_queue"'::regclass)
   AND to_regclass('"public"."merge_queue_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."merge_queue"
    ADD CONSTRAINT "merge_queue_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_activity_id_fkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_activity_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."crm_lead_activities"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_channel_session_id_fkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_channel_session_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_channel_session_id_fkey" FOREIGN KEY ("channel_session_id") REFERENCES "public"."channel_sessions"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_contact_id_fkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_conversation_id_fkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_conversation_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."conversations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_organization_id_fkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'messages_sent_by_user_id_fkey' AND conrelid = '"public"."messages"'::regclass)
   AND to_regclass('"public"."messages_sent_by_user_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sent_by_user_id_fkey" FOREIGN KEY ("sent_by_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'nuvemshop_products_organization_id_fkey' AND conrelid = '"public"."nuvemshop_products"'::regclass)
   AND to_regclass('"public"."nuvemshop_products_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."nuvemshop_products"
    ADD CONSTRAINT "nuvemshop_products_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'orders_contact_id_fkey' AND conrelid = '"public"."orders"'::regclass)
   AND to_regclass('"public"."orders_contact_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_contact_id_fkey" FOREIGN KEY ("contact_id") REFERENCES "public"."contacts"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'orders_organization_id_fkey' AND conrelid = '"public"."orders"'::regclass)
   AND to_regclass('"public"."orders_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'organizations_created_by_fkey' AND conrelid = '"public"."organizations"'::regclass)
   AND to_regclass('"public"."organizations_created_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'organizations_suspended_by_fkey' AND conrelid = '"public"."organizations"'::regclass)
   AND to_regclass('"public"."organizations_suspended_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_suspended_by_fkey" FOREIGN KEY ("suspended_by") REFERENCES "auth"."users"("id");
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'platform_admins_granted_by_fkey' AND conrelid = '"public"."platform_admins"'::regclass)
   AND to_regclass('"public"."platform_admins_granted_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."platform_admins"
    ADD CONSTRAINT "platform_admins_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'platform_admins_revoked_by_fkey' AND conrelid = '"public"."platform_admins"'::regclass)
   AND to_regclass('"public"."platform_admins_revoked_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."platform_admins"
    ADD CONSTRAINT "platform_admins_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'platform_admins_user_id_fkey' AND conrelid = '"public"."platform_admins"'::regclass)
   AND to_regclass('"public"."platform_admins_user_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."platform_admins"
    ADD CONSTRAINT "platform_admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'storage_redaction_queue_organization_id_fkey' AND conrelid = '"public"."storage_redaction_queue"'::regclass)
   AND to_regclass('"public"."storage_redaction_queue_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."storage_redaction_queue"
    ADD CONSTRAINT "storage_redaction_queue_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'storage_redaction_queue_request_id_fkey' AND conrelid = '"public"."storage_redaction_queue"'::regclass)
   AND to_regclass('"public"."storage_redaction_queue_request_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."storage_redaction_queue"
    ADD CONSTRAINT "storage_redaction_queue_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."lgpd_requests"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'tenant_integrations_organization_id_fkey' AND conrelid = '"public"."tenant_integrations"'::regclass)
   AND to_regclass('"public"."tenant_integrations_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."tenant_integrations"
    ADD CONSTRAINT "tenant_integrations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_organizations_invited_by_fkey' AND conrelid = '"public"."user_organizations"'::regclass)
   AND to_regclass('"public"."user_organizations_invited_by_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."user_organizations"
    ADD CONSTRAINT "user_organizations_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_organizations_organization_id_fkey' AND conrelid = '"public"."user_organizations"'::regclass)
   AND to_regclass('"public"."user_organizations_organization_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."user_organizations"
    ADD CONSTRAINT "user_organizations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_organizations_user_id_fkey' AND conrelid = '"public"."user_organizations"'::regclass)
   AND to_regclass('"public"."user_organizations_user_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."user_organizations"
    ADD CONSTRAINT "user_organizations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'user_recovery_codes_user_id_fkey' AND conrelid = '"public"."user_recovery_codes"'::regclass)
   AND to_regclass('"public"."user_recovery_codes_user_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."user_recovery_codes"
    ADD CONSTRAINT "user_recovery_codes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'webhook_events_log_channel_session_id_fkey' AND conrelid = '"public"."webhook_events_log"'::regclass)
   AND to_regclass('"public"."webhook_events_log_channel_session_id_fkey"') IS NULL THEN
ALTER TABLE ONLY "public"."webhook_events_log"
    ADD CONSTRAINT "webhook_events_log_channel_session_id_fkey" FOREIGN KEY ("channel_session_id") REFERENCES "public"."channel_sessions"("id") ON DELETE SET NULL;
END IF; END $baseline_guard$;



ALTER TABLE "public"."ai_agent_runs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_agent_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_agents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_budgets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_chunks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_faq_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_invocations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_knowledge_sources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_knowledge_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_models" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'ai_models_read_all' AND polrelid = '"public"."ai_models"'::regclass) THEN
CREATE POLICY "ai_models_read_all" ON "public"."ai_models" FOR SELECT USING (true);
END IF; END $baseline_guard$;



ALTER TABLE "public"."ai_pricing" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'ai_pricing_public_read' AND polrelid = '"public"."ai_pricing"'::regclass) THEN
CREATE POLICY "ai_pricing_public_read" ON "public"."ai_pricing" FOR SELECT USING (true);
END IF; END $baseline_guard$;



ALTER TABLE "public"."ai_provider_credentials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."api_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."api_tokens" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'api_tokens_admin_only' AND polrelid = '"public"."api_tokens"'::regclass) THEN
CREATE POLICY "api_tokens_admin_only" ON "public"."api_tokens" USING (("public"."fn_role_at_least"("organization_id", 'admin'::"text") OR "public"."fn_is_platform_admin"())) WITH CHECK (("public"."fn_role_at_least"("organization_id", 'admin'::"text") OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'audit_log_insert_tenant_member' AND polrelid = '"public"."api_audit_log"'::regclass) THEN
CREATE POLICY "audit_log_insert_tenant_member" ON "public"."api_audit_log" FOR INSERT TO "authenticated" WITH CHECK ((("organization_id" IS NULL) OR ("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'audit_log_select' AND polrelid = '"public"."api_audit_log"'::regclass) THEN
CREATE POLICY "audit_log_select" ON "public"."api_audit_log" FOR SELECT USING (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'admin'::"text"))));
END IF; END $baseline_guard$;



ALTER TABLE "public"."channel_session_warmup" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."channel_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."conversations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crm_lead_activities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crm_lead_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crm_leads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crm_pipelines" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."crm_stages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_log" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'event_log_select' AND polrelid = '"public"."event_log"'::regclass) THEN
CREATE POLICY "event_log_select" ON "public"."event_log" FOR SELECT USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



ALTER TABLE "public"."idempotency_keys" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'idempotency_tenant' AND polrelid = '"public"."idempotency_keys"'::regclass) THEN
CREATE POLICY "idempotency_tenant" ON "public"."idempotency_keys" USING (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids"))) WITH CHECK (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")));
END IF; END $baseline_guard$;



ALTER TABLE "public"."incidents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."lgpd_requests" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'lgpd_requests_admin_select' AND polrelid = '"public"."lgpd_requests"'::regclass) THEN
CREATE POLICY "lgpd_requests_admin_select" ON "public"."lgpd_requests" FOR SELECT USING (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'admin'::"text"))));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'lgpd_requests_admin_write' AND polrelid = '"public"."lgpd_requests"'::regclass) THEN
CREATE POLICY "lgpd_requests_admin_write" ON "public"."lgpd_requests" USING (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'admin'::"text")))) WITH CHECK (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'admin'::"text"))));
END IF; END $baseline_guard$;



ALTER TABLE "public"."merge_queue" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'merge_queue_manager_select' AND polrelid = '"public"."merge_queue"'::regclass) THEN
CREATE POLICY "merge_queue_manager_select" ON "public"."merge_queue" FOR SELECT USING (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'manager'::"text"))));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'merge_queue_manager_write' AND polrelid = '"public"."merge_queue"'::regclass) THEN
CREATE POLICY "merge_queue_manager_write" ON "public"."merge_queue" USING (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'manager'::"text")))) WITH CHECK (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'manager'::"text"))));
END IF; END $baseline_guard$;



ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nuvemshop_products" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'nuvemshop_products_tenant' AND polrelid = '"public"."nuvemshop_products"'::regclass) THEN
CREATE POLICY "nuvemshop_products_tenant" ON "public"."nuvemshop_products" USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"())) WITH CHECK ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'orders_tenant_select' AND polrelid = '"public"."orders"'::regclass) THEN
CREATE POLICY "orders_tenant_select" ON "public"."orders" FOR SELECT USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'orders_tenant_write' AND polrelid = '"public"."orders"'::regclass) THEN
CREATE POLICY "orders_tenant_write" ON "public"."orders" USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"())) WITH CHECK ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



ALTER TABLE "public"."organizations" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'orgs_select' AND polrelid = '"public"."organizations"'::regclass) THEN
CREATE POLICY "orgs_select" ON "public"."organizations" FOR SELECT USING ((("id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'orgs_write_platform_admin' AND polrelid = '"public"."organizations"'::regclass) THEN
CREATE POLICY "orgs_write_platform_admin" ON "public"."organizations" USING ("public"."fn_is_platform_admin"()) WITH CHECK ("public"."fn_is_platform_admin"());
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'platform_admin_only_incidents' AND polrelid = '"public"."incidents"'::regclass) THEN
CREATE POLICY "platform_admin_only_incidents" ON "public"."incidents" USING ("public"."fn_is_platform_admin"()) WITH CHECK ("public"."fn_is_platform_admin"());
END IF; END $baseline_guard$;



ALTER TABLE "public"."platform_admins" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'platform_admins_self' AND polrelid = '"public"."platform_admins"'::regclass) THEN
CREATE POLICY "platform_admins_self" ON "public"."platform_admins" FOR SELECT USING ("public"."fn_is_platform_admin"());
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'recovery_codes_self' AND polrelid = '"public"."user_recovery_codes"'::regclass) THEN
CREATE POLICY "recovery_codes_self" ON "public"."user_recovery_codes" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));
END IF; END $baseline_guard$;



ALTER TABLE "public"."storage_redaction_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tenant_integrations" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_integrations_admin_write' AND polrelid = '"public"."tenant_integrations"'::regclass) THEN
CREATE POLICY "tenant_integrations_admin_write" ON "public"."tenant_integrations" USING (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'manager'::"text")))) WITH CHECK (("public"."fn_is_platform_admin"() OR (("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) AND "public"."fn_role_at_least"("organization_id", 'manager'::"text"))));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_integrations_select' AND polrelid = '"public"."tenant_integrations"'::regclass) THEN
CREATE POLICY "tenant_integrations_select" ON "public"."tenant_integrations" FOR SELECT USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_isolation_ai_agent_runs_all' AND polrelid = '"public"."ai_agent_runs"'::regclass) THEN
CREATE POLICY "tenant_isolation_ai_agent_runs_all" ON "public"."ai_agent_runs" USING (("organization_id" IN ( SELECT "fn_user_org_ids"."fn_user_org_ids"
   FROM "public"."fn_user_org_ids"() "fn_user_org_ids"("fn_user_org_ids")))) WITH CHECK (("organization_id" IN ( SELECT "fn_user_org_ids"."fn_user_org_ids"
   FROM "public"."fn_user_org_ids"() "fn_user_org_ids"("fn_user_org_ids"))));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_isolation_ai_invocations_all' AND polrelid = '"public"."ai_invocations"'::regclass) THEN
CREATE POLICY "tenant_isolation_ai_invocations_all" ON "public"."ai_invocations" USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"())) WITH CHECK ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_isolation_ai_provider_credentials_select' AND polrelid = '"public"."ai_provider_credentials"'::regclass) THEN
CREATE POLICY "tenant_isolation_ai_provider_credentials_select" ON "public"."ai_provider_credentials" FOR SELECT USING (("organization_id" IN ( SELECT "fn_user_org_ids"."fn_user_org_ids"
   FROM "public"."fn_user_org_ids"() "fn_user_org_ids"("fn_user_org_ids"))));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_isolation_contacts_all' AND polrelid = '"public"."contacts"'::regclass) THEN
CREATE POLICY "tenant_isolation_contacts_all" ON "public"."contacts" USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"())) WITH CHECK ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'tenant_isolation_storage_redaction_queue_all' AND polrelid = '"public"."storage_redaction_queue"'::regclass) THEN
CREATE POLICY "tenant_isolation_storage_redaction_queue_all" ON "public"."storage_redaction_queue" USING (("organization_id" IN ( SELECT "fn_user_org_ids"."fn_user_org_ids"
   FROM "public"."fn_user_org_ids"() "fn_user_org_ids"("fn_user_org_ids")))) WITH CHECK (("organization_id" IN ( SELECT "fn_user_org_ids"."fn_user_org_ids"
   FROM "public"."fn_user_org_ids"() "fn_user_org_ids"("fn_user_org_ids"))));
END IF; END $baseline_guard$;



ALTER TABLE "public"."user_organizations" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'user_orgs_delete' AND polrelid = '"public"."user_organizations"'::regclass) THEN
CREATE POLICY "user_orgs_delete" ON "public"."user_organizations" FOR DELETE USING (("public"."fn_role_at_least"("organization_id", 'admin'::"text") OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'user_orgs_insert' AND polrelid = '"public"."user_organizations"'::regclass) THEN
CREATE POLICY "user_orgs_insert" ON "public"."user_organizations" FOR INSERT WITH CHECK (("public"."fn_role_at_least"("organization_id", 'admin'::"text") OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'user_orgs_select' AND polrelid = '"public"."user_organizations"'::regclass) THEN
CREATE POLICY "user_orgs_select" ON "public"."user_organizations" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR "public"."fn_role_at_least"("organization_id", 'admin'::"text") OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'user_orgs_update' AND polrelid = '"public"."user_organizations"'::regclass) THEN
CREATE POLICY "user_orgs_update" ON "public"."user_organizations" FOR UPDATE USING (("public"."fn_role_at_least"("organization_id", 'admin'::"text") OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



ALTER TABLE "public"."user_recovery_codes" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'warmup_tenant_isolation_all' AND polrelid = '"public"."channel_session_warmup"'::regclass) THEN
CREATE POLICY "warmup_tenant_isolation_all" ON "public"."channel_session_warmup" USING ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"())) WITH CHECK ((("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")) OR "public"."fn_is_platform_admin"()));
END IF; END $baseline_guard$;



ALTER TABLE "public"."webhook_events_log" ENABLE ROW LEVEL SECURITY;


DO $baseline_guard$ BEGIN
IF NOT EXISTS (SELECT 1 FROM pg_policy
                WHERE polname = 'webhook_events_log_tenant_read' AND polrelid = '"public"."webhook_events_log"'::regclass) THEN
CREATE POLICY "webhook_events_log_tenant_read" ON "public"."webhook_events_log" FOR SELECT USING (("public"."fn_is_platform_admin"() OR (("organization_id" IS NOT NULL) AND ("organization_id" IN ( SELECT "public"."fn_user_org_ids"() AS "fn_user_org_ids")))));
END IF; END $baseline_guard$;



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."activate_kb_version"("p_agent_id" "uuid", "p_version_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activate_kb_version"("p_agent_id" "uuid", "p_version_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."emit_event"("p_event_type" "text", "p_entity_kind" "text", "p_entity_id" "uuid", "p_payload" "jsonb", "p_metadata" "jsonb", "p_organization_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."emit_event"("p_event_type" "text", "p_entity_kind" "text", "p_entity_id" "uuid", "p_payload" "jsonb", "p_metadata" "jsonb", "p_organization_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_audit_log_row"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_crm_lead_close_on_stage"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_crm_lead_close_on_stage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_crm_lead_close_on_stage"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_decrypt_oauth"("ciphertext" "bytea") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_decrypt_oauth"("ciphertext" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_emit_channel_session_status_changed"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_emit_channel_session_status_changed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_emit_channel_session_status_changed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_emit_event_on_lead_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_emit_event_on_lead_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_emit_event_on_lead_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_emit_message_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_emit_message_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_emit_message_event"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_encrypt_oauth"("plaintext" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_encrypt_oauth"("plaintext" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_is_platform_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_is_platform_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_lgpd_cascade_redact_contact"("p_organization_id" "uuid", "p_contact_id" "uuid", "p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_lgpd_cascade_redact_contact"("p_organization_id" "uuid", "p_contact_id" "uuid", "p_request_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_log_event"("p_organization_id" "uuid", "p_event_type" "text", "p_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_log_event"("p_organization_id" "uuid", "p_event_type" "text", "p_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_publish_ai_agent_version"("p_org_id" "uuid", "p_agent_id" "uuid", "p_version_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_role_at_least"("p_org" "uuid", "p_min" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_role_at_least"("p_org" "uuid", "p_min" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_seed_default_pipeline_for_org"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_seed_default_pipeline_for_org"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_seed_default_pipeline_for_org"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_touch_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_update_budget_consumption"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_update_budget_consumption"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_update_last_activity_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_update_last_activity_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_update_last_activity_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_user_org_ids"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_user_org_ids"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_user_role_in"("p_org" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_user_role_in"("p_org" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_user_role_in_org"("p_org" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_user_role_in_org"("p_org" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_validate_activity_lead_org"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_validate_activity_lead_org"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_validate_activity_lead_org"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_validate_lost_reason_required"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_validate_lost_reason_required"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_validate_lost_reason_required"() TO "service_role";



GRANT ALL ON FUNCTION "public"."midpoint"("p_prev" numeric, "p_next" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."midpoint"("p_prev" numeric, "p_next" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."midpoint"("p_prev" numeric, "p_next" numeric) TO "service_role";



REVOKE ALL ON FUNCTION "public"."retrieve_top_k_chunks"("p_organization_id" "uuid", "p_kb_version_id" "uuid", "p_embedding" "public"."vector", "p_k" integer, "p_threshold" real) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."retrieve_top_k_chunks"("p_organization_id" "uuid", "p_kb_version_id" "uuid", "p_embedding" "public"."vector", "p_k" integer, "p_threshold" real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."retrieve_top_k_chunks"("p_organization_id" "uuid", "p_kb_version_id" "uuid", "p_embedding" "public"."vector", "p_k" integer, "p_threshold" real) TO "service_role";



GRANT ALL ON TABLE "public"."ai_agent_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_agent_runs" TO "service_role";



GRANT ALL ON TABLE "public"."ai_agent_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_agent_versions" TO "service_role";



GRANT ALL ON TABLE "public"."ai_agents" TO "anon";
GRANT ALL ON TABLE "public"."ai_agents" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_agents" TO "service_role";



GRANT ALL ON TABLE "public"."ai_budgets" TO "anon";
GRANT ALL ON TABLE "public"."ai_budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_budgets" TO "service_role";



GRANT ALL ON TABLE "public"."ai_chunks" TO "anon";
GRANT ALL ON TABLE "public"."ai_chunks" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_chunks" TO "service_role";



GRANT ALL ON TABLE "public"."ai_faq_items" TO "anon";
GRANT ALL ON TABLE "public"."ai_faq_items" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_faq_items" TO "service_role";



GRANT ALL ON TABLE "public"."ai_invocations" TO "anon";
GRANT ALL ON TABLE "public"."ai_invocations" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_invocations" TO "service_role";



GRANT ALL ON TABLE "public"."ai_knowledge_sources" TO "anon";
GRANT ALL ON TABLE "public"."ai_knowledge_sources" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_knowledge_sources" TO "service_role";



GRANT ALL ON TABLE "public"."ai_knowledge_versions" TO "anon";
GRANT ALL ON TABLE "public"."ai_knowledge_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_knowledge_versions" TO "service_role";



GRANT ALL ON TABLE "public"."ai_models" TO "anon";
GRANT ALL ON TABLE "public"."ai_models" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_models" TO "service_role";



GRANT ALL ON TABLE "public"."ai_pricing" TO "anon";
GRANT ALL ON TABLE "public"."ai_pricing" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_pricing" TO "service_role";



GRANT ALL ON TABLE "public"."ai_provider_credentials" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_provider_credentials" TO "service_role";



GRANT ALL ON TABLE "public"."ai_provider_credentials_safe" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_provider_credentials_safe" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."api_audit_log" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."api_audit_log" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."api_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."api_tokens" TO "anon";
GRANT ALL ON TABLE "public"."api_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."api_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."channel_session_warmup" TO "anon";
GRANT ALL ON TABLE "public"."channel_session_warmup" TO "authenticated";
GRANT ALL ON TABLE "public"."channel_session_warmup" TO "service_role";



GRANT ALL ON TABLE "public"."channel_sessions" TO "anon";
GRANT ALL ON TABLE "public"."channel_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."channel_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."contacts" TO "anon";
GRANT ALL ON TABLE "public"."contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."contacts" TO "service_role";



GRANT ALL ON TABLE "public"."conversations" TO "anon";
GRANT ALL ON TABLE "public"."conversations" TO "authenticated";
GRANT ALL ON TABLE "public"."conversations" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."crm_lead_activities" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."crm_lead_activities" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_lead_activities" TO "service_role";



GRANT ALL ON TABLE "public"."crm_lead_links" TO "anon";
GRANT ALL ON TABLE "public"."crm_lead_links" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_lead_links" TO "service_role";



GRANT ALL ON TABLE "public"."crm_leads" TO "anon";
GRANT ALL ON TABLE "public"."crm_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_leads" TO "service_role";



GRANT ALL ON TABLE "public"."crm_pipelines" TO "anon";
GRANT ALL ON TABLE "public"."crm_pipelines" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_pipelines" TO "service_role";



GRANT ALL ON TABLE "public"."crm_stages" TO "anon";
GRANT ALL ON TABLE "public"."crm_stages" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_stages" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."event_log" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."event_log" TO "authenticated";
GRANT ALL ON TABLE "public"."event_log" TO "service_role";



GRANT ALL ON TABLE "public"."idempotency_keys" TO "anon";
GRANT ALL ON TABLE "public"."idempotency_keys" TO "authenticated";
GRANT ALL ON TABLE "public"."idempotency_keys" TO "service_role";



GRANT ALL ON TABLE "public"."incidents" TO "anon";
GRANT ALL ON TABLE "public"."incidents" TO "authenticated";
GRANT ALL ON TABLE "public"."incidents" TO "service_role";



GRANT ALL ON TABLE "public"."lgpd_requests" TO "anon";
GRANT ALL ON TABLE "public"."lgpd_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."lgpd_requests" TO "service_role";



GRANT ALL ON TABLE "public"."merge_queue" TO "anon";
GRANT ALL ON TABLE "public"."merge_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."merge_queue" TO "service_role";



GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";



GRANT ALL ON TABLE "public"."nuvemshop_products" TO "anon";
GRANT ALL ON TABLE "public"."nuvemshop_products" TO "authenticated";
GRANT ALL ON TABLE "public"."nuvemshop_products" TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";



GRANT ALL ON TABLE "public"."platform_admins" TO "anon";
GRANT ALL ON TABLE "public"."platform_admins" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_admins" TO "service_role";



GRANT ALL ON TABLE "public"."storage_redaction_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."storage_redaction_queue" TO "service_role";



GRANT ALL ON TABLE "public"."tenant_integrations" TO "anon";
GRANT ALL ON TABLE "public"."tenant_integrations" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_integrations" TO "service_role";



GRANT ALL ON TABLE "public"."user_organizations" TO "anon";
GRANT ALL ON TABLE "public"."user_organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."user_organizations" TO "service_role";



GRANT ALL ON TABLE "public"."user_recovery_codes" TO "anon";
GRANT ALL ON TABLE "public"."user_recovery_codes" TO "authenticated";
GRANT ALL ON TABLE "public"."user_recovery_codes" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."webhook_events_log" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE "public"."webhook_events_log" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_events_log" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";








-- ============================================================================
-- COMPLEMENTO DO BASELINE (não capturado pelo dump --schema public):
--   storage buckets + policies (migrations 0014/0017) e realtime publication.
--   Aplicar DEPOIS do schema public (dependem de public.user_organizations).
-- ============================================================================

-- ---- storage: bucket ai-policy + policies (migration 0014) ----

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ai-policy',
  'ai-policy',
  false,
  20971520,
  array['application/pdf', 'text/markdown', 'text/x-markdown', 'text/plain']
)
on conflict (id) do nothing;

drop policy if exists "tenant_read_ai_policy" on storage.objects;
create policy "tenant_read_ai_policy" on storage.objects for select
  using (
    bucket_id = 'ai-policy'
    and exists (
      select 1 from public.user_organizations uo
      where uo.user_id = auth.uid()
        and uo.revoked_at is null
        and uo.organization_id = (split_part(name, '/', 1))::uuid
    )
  );

drop policy if exists "tenant_write_ai_policy" on storage.objects;
create policy "tenant_write_ai_policy" on storage.objects for insert
  with check (
    bucket_id = 'ai-policy'
    and exists (
      select 1 from public.user_organizations uo
      where uo.user_id = auth.uid()
        and uo.revoked_at is null
        and uo.organization_id = (split_part(name, '/', 1))::uuid
    )
  );

drop policy if exists "tenant_delete_ai_policy" on storage.objects;
create policy "tenant_delete_ai_policy" on storage.objects for delete
  using (
    bucket_id = 'ai-policy'
    and exists (
      select 1 from public.user_organizations uo
      where uo.user_id = auth.uid()
        and uo.revoked_at is null
        and uo.organization_id = (split_part(name, '/', 1))::uuid
    )
  );

-- ---- storage: bucket lgpd-exports + policy (migration 0017) ----

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'lgpd-exports',
  'lgpd-exports',
  false,
  52428800,
  array['application/pdf', 'application/json']
)
on conflict (id) do nothing;

drop policy if exists "tenant_read_lgpd_exports" on storage.objects;
create policy "tenant_read_lgpd_exports" on storage.objects for select
  using (
    bucket_id = 'lgpd-exports'
    and exists (
      select 1 from public.user_organizations uo
      where uo.user_id = auth.uid()
        and uo.revoked_at is null
        and uo.organization_id = (split_part(name, '/', 1))::uuid
    )
  );

-- ---- bucket de assets de skills (migration 0068) ----
insert into storage.buckets (id, name, public, file_size_limit)
values ('skill-assets', 'skill-assets', false, 5242880)
on conflict (id) do nothing;

-- Leitura por org (path {org_id}/...) OU plataforma (path platform/...) por qualquer
-- usuário autenticado (assets de plataforma são públicos p/ tenants; conteúdo é curado).
drop policy if exists "skill_assets_read" on storage.objects;
create policy "skill_assets_read" on storage.objects for select to authenticated
  using (
    bucket_id = 'skill-assets'
    and (
      split_part(name, '/', 1) = 'platform'
      or exists (
        select 1 from public.user_organizations uo
        where uo.user_id = auth.uid() and uo.revoked_at is null
          and uo.organization_id = (split_part(name, '/', 1))::uuid
      )
    )
  );
-- Escrita/DELETE de assets é sempre via service role (rota de import) — sem policy de write.

-- ---- realtime: inbox (messages/conversations), kanban (crm_leads) e IA ----
do $$ begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;
do $$
declare t text;
begin
  -- crm_lead_activities (migration 0071): o dossiê assina a timeline filtrada
  -- por lead_id (§3.5). O board não assina esta tabela — ele escuta crm_leads
  -- por pipeline_id, e toda atividade toca o lead via fn_update_last_activity_at.
  foreach t in array array['messages','conversations','crm_leads','ai_agents','ai_agent_runs','ai_knowledge_sources','crm_lead_activities']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---- ai_models: catálogo curado global (migration 0023, §Seed Spec 10 §2.2) ----
-- Também não capturado pelo dump --schema-only. Sem isto, /api/v1/ai/providers/:p/models
-- devolve lista vazia pra todo provedor e o seletor de modelo do agente fica sem opções.
insert into public.ai_models (provider, model_id, display_name, description, context_window, input_price_per_million_cents, output_price_per_million_cents, supports_tools, is_default_for_provider)
values
  ('anthropic', 'claude-opus-4-7',    'Claude Opus 4.7',    'Flagship Anthropic — raciocínio complexo',                  200000,  1500, 7500, true, false),
  ('anthropic', 'claude-sonnet-4-6',  'Claude Sonnet 4.6',  'Default recomendado — equilíbrio custo/qualidade',           200000,   300, 1500, true, true),
  ('anthropic', 'claude-haiku-4-5',   'Claude Haiku 4.5',   'Cheap/fast — atendimentos curtos e classificação',           200000,   100,  500, true, false),
  ('openai',    'gpt-5',              'GPT-5',              'Flagship OpenAI',                                           400000,   500, 4000, true, false),
  ('openai',    'gpt-5-mini',         'GPT-5 Mini',         'Cheap/fast OpenAI',                                         400000,   150,  600, true, true),
  ('openai',    'gpt-4o',             'GPT-4o (legacy)',    'Compat — uso legado',                                       128000,   250, 1000, true, false),
  ('google',    'gemini-2.5-pro',     'Gemini 2.5 Pro',     'Flagship Google',                                          1000000,   125,  500, true, false),
  ('google',    'gemini-2.5-flash',   'Gemini 2.5 Flash',   'Cheap/fast Google',                                        1000000,    30,  120, true, true)
on conflict (provider, model_id) do nothing;

-- ---- WhatsApp: unificação de conversas por contato (migration 0027) ----
-- O dump --schema-only não traz mudanças pós-snapshot. Sem este bloco, clones
-- (install.sh) e clones atualizando (update.sh, que re-aplica baseline.sql)
-- ficam com o bug: 1 pessoa vira N contatos/conversas (WAHA emite
-- message+message.any por mensagem; contatos @lid sem unique + check-then-act).
-- Idempotente e AUTO-CURATIVO: em banco novo o dedup é no-op; em clone já bugado
-- ele deduplica o histórico ANTES de criar as constraints. Ver a migration
-- 20260706210000_0027_whatsapp_conversation_unification.sql para o detalhe.

-- A. Identidade canônica (generated)
alter table public.contacts
  add column if not exists wa_identity text
  generated always as (
    case
      when phone_number is not null then 'phone:' || phone_number
      when source_metadata->>'waha_lid' is not null
        then 'lid:' || regexp_replace(source_metadata->>'waha_lid', '@.*$', '')
      else null
    end
  ) stored;

-- B1. Merge de contatos duplicados (usa is_merged_into como mapa; sem temp tables)
with ranked as (
  select id, first_value(id) over (partition by organization_id, wa_identity order by created_at asc, id asc) as canonical_id
  from public.contacts where wa_identity is not null and is_merged_into is null
)
update public.contacts c set is_merged_into = r.canonical_id, merged_at = now()
from ranked r where c.id = r.id and r.id <> r.canonical_id;

update public.conversations       t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;
update public.messages            t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;
update public.ai_agent_runs       t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;
update public.crm_lead_activities t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;
update public.crm_leads           t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;
update public.lgpd_requests       t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;
update public.orders              t set contact_id = c.is_merged_into from public.contacts c where t.contact_id = c.id and c.is_merged_into is not null;

update public.contacts can set display_name = better.name
from (
  select coalesce(c.is_merged_into, c.id) as canonical_id,
    (array_agg(c.display_name order by (c.display_name ~ '^Contato ') asc, c.created_at asc)
       filter (where c.display_name is not null and c.display_name <> ''))[1] as name
  from public.contacts c
  where coalesce(c.is_merged_into, c.id) in (select is_merged_into from public.contacts where is_merged_into is not null)
  group by 1
) better
where can.id = better.canonical_id and better.name is not null
  and (can.display_name is null or can.display_name = '' or can.display_name ~ '^Contato ');

-- B2. Merge de conversas 1:1 duplicadas
update public.messages t set conversation_id = canon.canonical_id
from (select id, first_value(id) over (partition by organization_id, contact_id, channel_session_id order by created_at asc, id asc) as canonical_id from public.conversations where is_group = false) canon
where t.conversation_id = canon.id and canon.id <> canon.canonical_id;
update public.ai_agent_runs t set conversation_id = canon.canonical_id
from (select id, first_value(id) over (partition by organization_id, contact_id, channel_session_id order by created_at asc, id asc) as canonical_id from public.conversations where is_group = false) canon
where t.conversation_id = canon.id and canon.id <> canon.canonical_id;
update public.ai_invocations t set conversation_id = canon.canonical_id
from (select id, first_value(id) over (partition by organization_id, contact_id, channel_session_id order by created_at asc, id asc) as canonical_id from public.conversations where is_group = false) canon
where t.conversation_id = canon.id and canon.id <> canon.canonical_id;
delete from public.conversations d
using (select id, first_value(id) over (partition by organization_id, contact_id, channel_session_id order by created_at asc, id asc) as canonical_id from public.conversations where is_group = false) canon
where d.id = canon.id and canon.id <> canon.canonical_id;

-- C. Constraints anti-reduplicação
create unique index if not exists uniq_contacts_org_wa_identity
  on public.contacts (organization_id, wa_identity)
  where wa_identity is not null and is_merged_into is null;
create unique index if not exists uniq_conversations_1to1_per_contact_session
  on public.conversations (organization_id, contact_id, channel_session_id)
  where is_group = false;

-- D. Upsert atômico (a aplicação usa via lib/waha/ingest.ts)
create or replace function public.fn_upsert_wa_contact(
  p_org uuid, p_kind text, p_phone text, p_lid text, p_chat_id text, p_notify text
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.contacts (organization_id, phone_number, source, consent, tags, source_metadata, display_name)
  values (p_org, case when p_kind = 'phone' then p_phone end, 'whatsapp', '{}'::jsonb, '{}'::text[],
    case when p_kind = 'lid' then jsonb_build_object('waha_lid', p_lid, 'notify_name', nullif(p_notify, ''))
      else jsonb_build_object('waha_chat_id', p_chat_id, 'notify_name', nullif(p_notify, '')) end,
    nullif(p_notify, ''))
  on conflict (organization_id, wa_identity) where wa_identity is not null and is_merged_into is null
  do update set display_name = coalesce(contacts.display_name, excluded.display_name), updated_at = now()
  returning id into v_id;
  return v_id;
end; $$;

create or replace function public.fn_upsert_wa_conversation(
  p_org uuid, p_contact uuid, p_session uuid
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.conversations (organization_id, contact_id, channel_session_id, channel, status, is_group, unread_count_for_assignee, metadata)
  values (p_org, p_contact, p_session, 'whatsapp', 'open', false, 0, '{}'::jsonb)
  on conflict (organization_id, contact_id, channel_session_id) where is_group = false
  do update set updated_at = now()
  returning id into v_id;
  return v_id;
end; $$;

create or replace function public.fn_mark_conversation_message(
  p_conv uuid, p_direction text, p_preview text, p_at timestamptz
) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set
    last_message_at = p_at, last_message_preview = p_preview,
    last_inbound_at  = case when p_direction = 'inbound'  then p_at else last_inbound_at  end,
    last_outbound_at = case when p_direction = 'outbound' then p_at else last_outbound_at end,
    unread_count_for_assignee = case
      when p_direction = 'inbound'  then unread_count_for_assignee + 1
      when p_direction = 'outbound' then 0
      else unread_count_for_assignee
    end,
    updated_at = now()
  where id = p_conv;
end; $$;

revoke all on function public.fn_upsert_wa_contact(uuid, text, text, text, text, text) from public;
revoke all on function public.fn_upsert_wa_conversation(uuid, uuid, uuid) from public;
revoke all on function public.fn_mark_conversation_message(uuid, text, text, timestamptz) from public;
grant execute on function public.fn_upsert_wa_contact(uuid, text, text, text, text, text) to service_role;
grant execute on function public.fn_upsert_wa_conversation(uuid, uuid, uuid) to service_role;
grant execute on function public.fn_mark_conversation_message(uuid, text, text, timestamptz) to service_role;

-- ---- RLS por role em tabelas de config + viewer read-only (migration 0030) ----
-- G2-03: spec 13 §4 — pipelines/stages (config) write manager+; conversations
-- write agent+ (viewer read-only). SELECT permanece org-flat (escopo own é G4).
-- Idempotente: drop if exists + create (auto-curativo no update.sh de clones).
-- Em conversations este bloco só DERRUBA a policy ampla: o SELECT e a escrita
-- que valem hoje nascem na 0035. Recriar aqui a versão intermediária (SELECT
-- org-flat, escrita agent+ FOR ALL) fazia cada update.sh reabri-la até a 0035.

drop policy if exists "tenant_isolation_crm_pipelines_all" on public.crm_pipelines;
drop policy if exists "crm_pipelines_select" on public.crm_pipelines;
drop policy if exists "crm_pipelines_manager_write" on public.crm_pipelines;

create policy "crm_pipelines_select" on public.crm_pipelines
  for select using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

create policy "crm_pipelines_manager_write" on public.crm_pipelines
  using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  )
  with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  );

drop policy if exists "tenant_isolation_crm_stages_all" on public.crm_stages;
drop policy if exists "crm_stages_select" on public.crm_stages;
drop policy if exists "crm_stages_manager_write" on public.crm_stages;

create policy "crm_stages_select" on public.crm_stages
  for select using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

create policy "crm_stages_manager_write" on public.crm_stages
  using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  )
  with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  );

drop policy if exists "conversations_tenant_isolation_all" on public.conversations;
drop policy if exists "conversations_agent_write" on public.conversations;

-- ---- Auditoria de atribuição de conversas + fn_conversation_assign (migration 0031) ----
-- G3-01 (gov-loop): toda mudança de dono de conversa vira evento estruturado
-- (spec 13 §3.1) e as rotas de claim/transfer/release passam a mudar o dono via
-- fn_conversation_assign — UPDATE condicional + INSERT do evento na MESMA
-- transação (spec 04 §9; 0 rows = optimistic lock perdeu → 409). Idempotente:
-- em clone atualizado é no-op; sem dados a corrigir.

create table if not exists public.conversation_assignment_events (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  from_user_id    uuid references auth.users(id) on delete set null,
  to_user_id      uuid references auth.users(id) on delete set null,
  changed_by      uuid references auth.users(id) on delete set null,
  reason          text not null
                  check (reason in ('claim','transfer','release','routing','handoff')),
  created_at      timestamptz not null default now()
);

create index if not exists idx_cae_conversation
  on public.conversation_assignment_events (conversation_id, created_at desc);

alter table public.conversation_assignment_events enable row level security;

-- cae_select nasce na 0173, com o escopo da conversa. A versão org-flat que
-- vivia aqui era reinstalada a cada update.sh e valia até aquele bloco.

-- `cae_insert` não nasce mais aqui, e nem é derrubada aqui: desde a 0279 a
-- tabela é server-only, e o INSERT legítimo é feito por dentro de
-- `fn_conversation_assign`, que é `security definer`. Quem a derruba — no clone
-- que já a tem — é o bloco da 0279, lá embaixo, junto do revoke. Criar aqui para
-- derrubar lá faria a regra antiga valer no meio de cada instalação
-- (tests/unit/baseline-nao-constroi-o-que-derruba.test.ts); derrubar aqui deixaria
-- a tabela sem policy nenhuma por 20 mil linhas de DDL, que num `update.sh` sobre
-- banco vivo é uma janela de leitura vazia na tela.

revoke all on public.conversation_assignment_events from anon;

create or replace function public.fn_conversation_assign(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_to_user_id uuid,
  p_reason text,
  p_expected_assignee uuid default null,
  p_enforce_expected boolean default false
) returns setof public.conversations
language plpgsql
set search_path = public
as $$
declare
  v_from uuid;
  v_conv public.conversations%rowtype;
begin
  select assigned_to_user_id into v_from
    from public.conversations
   where id = p_conversation_id
     and organization_id = p_organization_id
   for update;

  if not found then
    return;
  end if;

  if p_enforce_expected and v_from is distinct from p_expected_assignee then
    return;
  end if;

  update public.conversations
     set assigned_to_user_id = p_to_user_id,
         assigned_at = case when p_to_user_id is null then null else now() end,
         status = case when p_to_user_id is null then 'open' else 'claimed' end,
         status_changed_at = now(),
         unread_count_for_assignee = 0,
         updated_at = now()
   where id = p_conversation_id
   returning * into v_conv;

  insert into public.conversation_assignment_events
    (organization_id, conversation_id, from_user_id, to_user_id, changed_by, reason)
  values
    (p_organization_id, p_conversation_id, v_from, p_to_user_id, auth.uid(), p_reason);

  return next v_conv;
end;
$$;

revoke all on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean) from public;
grant execute on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean)
  to authenticated, service_role;

-- ---- assignee_kind + guard de membership na fn_conversation_assign (migration 0032) ----
-- G3-02 (gov-loop): IA como assignee de 1ª classe (spec 13 §3.2). Coluna
-- conversations.assignee_kind ('user'|'ai') + CHECK de coerência em forma de
-- implicação (kind='user' ⇒ dono humano; kind='ai' ⇒ sem dono; kind null livre
-- pra escritas legadas). Backfill ANTES da constraint (auto-curativo em clones).
-- Forward-fix INB-06a: fn_conversation_assign valida DENTRO da função que o
-- destino é membro ativo agent+ da org (via fn_member_role_in_org, SECURITY
-- DEFINER) e mantém assignee_kind coerente em claim/transfer/release/handoff.
-- fn_member_role_in_org é executável APENAS por authenticated (responde só a
-- membro ativo da org) e service_role (auth.uid() null); anon tem EXECUTE
-- revogado EXPLICITAMENTE — o default privilege do Supabase concede EXECUTE a
-- anon em toda função nova e o JWT anon também tem uid null.

alter table public.conversations
  add column if not exists assignee_kind text
  check (assignee_kind in ('user','ai'));

update public.conversations
   set assignee_kind = 'user'
 where assigned_to_user_id is not null
   and assignee_kind is distinct from 'user';

update public.conversations
   set assignee_kind = null
 where assigned_to_user_id is null
   and assignee_kind = 'user';

update public.conversations
   set assignee_kind = 'ai'
 where status = 'ai_handling'
   and assigned_to_user_id is null
   and assignee_kind is distinct from 'ai';

alter table public.conversations
  drop constraint if exists conversations_assignee_kind_coherence;
alter table public.conversations
  add constraint conversations_assignee_kind_coherence check (
    (assignee_kind = 'user' and assigned_to_user_id is not null) or
    (assignee_kind = 'ai'   and assigned_to_user_id is null)     or
    (assignee_kind is null)
  );

create or replace function public.fn_member_role_in_org(p_user uuid, p_org uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select uo.role
    from public.user_organizations uo
   where uo.user_id = p_user
     and uo.organization_id = p_org
     and uo.revoked_at is null
     and (
       auth.uid() is null
       or exists (
         select 1 from public.user_organizations me
          where me.user_id = auth.uid()
            and me.organization_id = p_org
            and me.revoked_at is null
       )
     )
   limit 1;
$$;

revoke all on function public.fn_member_role_in_org(uuid, uuid) from public;
-- O revoke from public NÃO cobre o grant DIRETO que anon carrega via
-- ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO anon (padrão
-- Supabase). Sem esta linha, o PostgREST expõe a função como RPC pública
-- (anon key vai pro browser) e o ramo auth.uid() null responde a request
-- anônimo — enumeração de membership/role de qualquer tenant.
revoke execute on function public.fn_member_role_in_org(uuid, uuid) from anon;
grant execute on function public.fn_member_role_in_org(uuid, uuid)
  to authenticated, service_role;

create or replace function public.fn_conversation_assign(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_to_user_id uuid,
  p_reason text,
  p_expected_assignee uuid default null,
  p_enforce_expected boolean default false
) returns setof public.conversations
language plpgsql
set search_path = public
as $$
declare
  v_from uuid;
  v_conv public.conversations%rowtype;
begin
  if p_to_user_id is not null then
    if coalesce(public.fn_member_role_in_org(p_to_user_id, p_organization_id), 'none')
         not in ('agent','manager','admin') then
      raise exception 'assignee_not_eligible_member'
        using hint = 'target must be an active agent+ member of the organization';
    end if;
  end if;

  select assigned_to_user_id into v_from
    from public.conversations
   where id = p_conversation_id
     and organization_id = p_organization_id
   for update;

  if not found then
    return;
  end if;

  if p_enforce_expected and v_from is distinct from p_expected_assignee then
    return;
  end if;

  update public.conversations
     set assigned_to_user_id = p_to_user_id,
         assigned_at = case when p_to_user_id is null then null else now() end,
         assignee_kind = case when p_to_user_id is null then null else 'user' end,
         status = case when p_to_user_id is null then 'open' else 'claimed' end,
         status_changed_at = now(),
         unread_count_for_assignee = 0,
         updated_at = now()
   where id = p_conversation_id
   returning * into v_conv;

  insert into public.conversation_assignment_events
    (organization_id, conversation_id, from_user_id, to_user_id, changed_by, reason)
  values
    (p_organization_id, p_conversation_id, v_from, p_to_user_id, auth.uid(), p_reason);

  return next v_conv;
end;
$$;

revoke all on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean) from public;
grant execute on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean)
  to authenticated, service_role;


-- ---- conversation tags (migration 0033) ----
-- G3-05 (gov-loop): eixo 7 — tags de conversa (spec 13 §3.3). Mesmo shape de
-- contacts.tags/crm_leads.tags (text[] + GIN). Vocabulário canônico em
-- organizations.settings.canonical_conversation_tags (org-scoped), semeado só
-- onde ausente. Idempotente/auto-curativo.
alter table public.conversations
  add column if not exists tags text[] not null default '{}';

create index if not exists idx_conversations_tags_gin
  on public.conversations using gin (tags);

update public.organizations
   set settings = coalesce(settings, '{}'::jsonb)
       || jsonb_build_object(
            'canonical_conversation_tags',
            jsonb_build_array(
              'dúvida', 'reclamação', 'troca', 'devolução',
              'elogio', 'orçamento', 'pós-venda', 'urgente'
            )
          )
 where not (coalesce(settings, '{}'::jsonb) ? 'canonical_conversation_tags');


-- ---- revoke anon EXECUTE em SECURITY DEFINER de escrita (migration 0034) ----
-- G4-00 (gov-loop): defesa em profundidade (INB-07). Duas origens de EXECUTE a
-- anon: (A) grant DIRETO do ALTER DEFAULT PRIVILEGES ... TO anon acima (funções
-- criadas depois dele, já sem grant a PUBLIC) → revoke anon; (B) grant via
-- PUBLIC (funções criadas ANTES do ALTER e nunca revogadas de public) → revoke
-- public + re-afirma authenticated/service_role (call sites legítimos). Nenhum
-- fluxo anônimo depende delas. Idempotente/auto-curativo.
revoke execute on function public.fn_upsert_wa_contact(uuid, text, text, text, text, text) from anon;
revoke execute on function public.fn_upsert_wa_conversation(uuid, uuid, uuid) from anon;
revoke execute on function public.fn_mark_conversation_message(uuid, text, text, timestamptz) from anon;

revoke execute on function public.emit_event(text, text, uuid, jsonb, jsonb, uuid) from public;
revoke execute on function public.emit_event(text, text, uuid, jsonb, jsonb, uuid) from anon;
grant execute on function public.emit_event(text, text, uuid, jsonb, jsonb, uuid) to authenticated, service_role;

revoke execute on function public.fn_log_event(uuid, text, jsonb) from public;
revoke execute on function public.fn_log_event(uuid, text, jsonb) from anon;
grant execute on function public.fn_log_event(uuid, text, jsonb) to authenticated, service_role;

revoke execute on function public.fn_audit_log_row() from public;
revoke execute on function public.fn_audit_log_row() from anon;
grant execute on function public.fn_audit_log_row() to service_role;


-- ---- visibility_mode: RLS de conversas/mensagens por atendente (migration 0035) ----
-- G4-01 (gov-loop): eixo 5 (spec 13 §3.5 + §4). organizations.settings.visibility_mode
-- ('all'|'own_and_unassigned'|'own', default 'own_and_unassigned' — G1-06a) restringe o
-- SELECT de conversations/messages APENAS para o role agent; viewer/manager/admin seguem
-- org-wide read. fn_can_view_conversation recebe os campos da ROW (evita lookup/recursão
-- por-row); DEFINER + search_path blindado + revoke anon/public (lição G4-00). A escrita
-- 0030 era FOR ALL, cujo USING também governa SELECT (policies OR-adas) — por isso é
-- re-expressa por-comando (mesmo agent+/org; quem escreve não muda), removendo só o grant
-- implícito de SELECT. messages SELECT herda o escopo da conversa via exists(). Idempotente,
-- auto-curativo. Escrita não restringida; ingestão/outbound via service_role bypassa RLS.

create or replace function public.fn_can_view_conversation(
  p_org uuid,
  p_assigned_to_user_id uuid
) returns boolean
language sql stable security definer
set search_path = public
as $$
  select case
    when public.fn_is_platform_admin() then true
    when public.fn_user_role_in_org(p_org) is null then false
    when public.fn_user_role_in_org(p_org) in ('viewer','manager','admin') then true
    when p_assigned_to_user_id = auth.uid() then true
    else case coalesce(
           (select settings->>'visibility_mode' from public.organizations where id = p_org),
           'own_and_unassigned')
         when 'all' then true
         when 'own_and_unassigned' then p_assigned_to_user_id is null
         else false
       end
  end;
$$;

revoke all on function public.fn_can_view_conversation(uuid, uuid) from public;
revoke execute on function public.fn_can_view_conversation(uuid, uuid) from anon;
grant execute on function public.fn_can_view_conversation(uuid, uuid)
  to authenticated, service_role;

drop policy if exists "conversations_select" on public.conversations;
create policy "conversations_select" on public.conversations
  for select using (
    public.fn_can_view_conversation(organization_id, assigned_to_user_id)
  );

drop policy if exists "conversations_agent_write" on public.conversations;
drop policy if exists "conversations_agent_insert" on public.conversations;
drop policy if exists "conversations_agent_update" on public.conversations;
drop policy if exists "conversations_agent_delete" on public.conversations;

create policy "conversations_agent_insert" on public.conversations
  for insert with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent'))
  );
create policy "conversations_agent_update" on public.conversations
  for update using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent'))
  ) with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent'))
  );
create policy "conversations_agent_delete" on public.conversations
  for delete using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent'))
  );

drop policy if exists "messages_tenant_isolation_all" on public.messages;
drop policy if exists "messages_select" on public.messages;
drop policy if exists "messages_insert" on public.messages;
drop policy if exists "messages_update" on public.messages;
drop policy if exists "messages_delete" on public.messages;

create policy "messages_select" on public.messages
  for select using (
    public.fn_is_platform_admin()
    or exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
    )
  );

create policy "messages_insert" on public.messages
  for insert with check (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );
create policy "messages_update" on public.messages
  for update using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  ) with check (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );
create policy "messages_delete" on public.messages
  for delete using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

-- Forward-fix do G4-01: fn_conversation_assign (0031/0032) passa a SECURITY
-- DEFINER. Com o SELECT de conversations visibility-aware, o `update ... returning
-- *` re-aplica a policy de SELECT à NOVA linha — numa transferência o dono passa a
-- ser outro atendente, invisível ao autor, e o RETURNING falharia. DEFINER bypassa
-- a RLS na escrita interna; a autorização do caller (antes garantida pela RLS
-- INVOKER) é re-afirmada dentro da função: agent+ ativo da MESMA org (service_role
-- com auth.uid() null é dispensado). Corpo idêntico ao 0032 fora o guard.
create or replace function public.fn_conversation_assign(
  p_organization_id uuid,
  p_conversation_id uuid,
  p_to_user_id uuid,
  p_reason text,
  p_expected_assignee uuid default null,
  p_enforce_expected boolean default false
) returns setof public.conversations
language plpgsql security definer
set search_path = public
as $$
declare
  v_from uuid;
  v_conv public.conversations%rowtype;
begin
  if auth.uid() is not null
     and not public.fn_role_at_least(p_organization_id, 'agent') then
    raise exception 'caller_not_authorized_for_org'
      using hint = 'caller must be an active agent+ member of the organization';
  end if;

  if p_to_user_id is not null then
    if coalesce(public.fn_member_role_in_org(p_to_user_id, p_organization_id), 'none')
         not in ('agent','manager','admin') then
      raise exception 'assignee_not_eligible_member'
        using hint = 'target must be an active agent+ member of the organization';
    end if;
  end if;

  select assigned_to_user_id into v_from
    from public.conversations
   where id = p_conversation_id
     and organization_id = p_organization_id
   for update;

  if not found then
    return;
  end if;

  if p_enforce_expected and v_from is distinct from p_expected_assignee then
    return;
  end if;

  update public.conversations
     set assigned_to_user_id = p_to_user_id,
         assigned_at = case when p_to_user_id is null then null else now() end,
         assignee_kind = case when p_to_user_id is null then null else 'user' end,
         status = case when p_to_user_id is null then 'open' else 'claimed' end,
         status_changed_at = now(),
         unread_count_for_assignee = 0,
         updated_at = now()
   where id = p_conversation_id
   returning * into v_conv;

  insert into public.conversation_assignment_events
    (organization_id, conversation_id, from_user_id, to_user_id, changed_by, reason)
  values
    (p_organization_id, p_conversation_id, v_from, p_to_user_id, auth.uid(), p_reason);

  return next v_conv;
end;
$$;

revoke all on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean) from public;
revoke execute on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean) from anon;
grant execute on function public.fn_conversation_assign(uuid, uuid, uuid, text, uuid, boolean)
  to authenticated, service_role;

-- ---- visibility_mode: RLS de crm_leads (kanban) por atendente (migration 0036) ----
-- G4-03 (gov-loop): eixo 5 (spec 13 §4 linha 220). Espelha a G4-01 (conversations,
-- 0035) para crm_leads — "dono" do lead = owner_user_id (não assigned_to). REUSE do
-- mesmo organizations.settings.visibility_mode ('all'|'own_and_unassigned'|'own',
-- default 'own_and_unassigned' — G1-06a; a matriz diz "mesmo escopo"). Só o role
-- agent é restrito; viewer/manager/admin org-wide read; platform_admin tudo.
-- fn_can_view_lead recebe os campos da ROW (sem lookup/recursão); DEFINER +
-- search_path blindado + revoke anon/public (lição G4-00). A FOR ALL org-flat
-- `tenant_isolation_crm_leads_all` governava SELECT junto (USING OR-ado) — dropada e
-- re-expressa por-comando: SELECT visibility-aware + escrita por-role (agent=own-scope
-- via a mesma fn, manager+=org-wide, viewer=none via piso 'agent'). Drag-and-drop de
-- lead próprio (UPDATE de stage/position sem mudar owner) passa; lead de outro agent
-- bloqueado; bulk assign (G3-04, ≥manager) intacto. Idempotente, auto-curativo.

create or replace function public.fn_can_view_lead(
  p_org uuid,
  p_owner_user_id uuid
) returns boolean
language sql stable security definer
set search_path = public
as $$
  select case
    when public.fn_is_platform_admin() then true
    when public.fn_user_role_in_org(p_org) is null then false
    when public.fn_user_role_in_org(p_org) in ('viewer','manager','admin') then true
    when p_owner_user_id = auth.uid() then true
    else case coalesce(
           (select settings->>'visibility_mode' from public.organizations where id = p_org),
           'own_and_unassigned')
         when 'all' then true
         when 'own_and_unassigned' then p_owner_user_id is null
         else false
       end
  end;
$$;

revoke all on function public.fn_can_view_lead(uuid, uuid) from public;
revoke execute on function public.fn_can_view_lead(uuid, uuid) from anon;
grant execute on function public.fn_can_view_lead(uuid, uuid)
  to authenticated, service_role;

drop policy if exists "tenant_isolation_crm_leads_all" on public.crm_leads;
drop policy if exists "crm_leads_select" on public.crm_leads;
drop policy if exists "crm_leads_insert" on public.crm_leads;
drop policy if exists "crm_leads_update" on public.crm_leads;
drop policy if exists "crm_leads_delete" on public.crm_leads;

create policy "crm_leads_select" on public.crm_leads
  for select using (
    public.fn_can_view_lead(organization_id, owner_user_id)
  );

create policy "crm_leads_insert" on public.crm_leads
  for insert with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent')
        and (public.fn_role_at_least(organization_id, 'manager')
             or public.fn_can_view_lead(organization_id, owner_user_id)))
  );
create policy "crm_leads_update" on public.crm_leads
  for update using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent')
        and (public.fn_role_at_least(organization_id, 'manager')
             or public.fn_can_view_lead(organization_id, owner_user_id)))
  ) with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent')
        and (public.fn_role_at_least(organization_id, 'manager')
             or public.fn_can_view_lead(organization_id, owner_user_id)))
  );
create policy "crm_leads_delete" on public.crm_leads
  for delete using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'agent')
        and (public.fn_role_at_least(organization_id, 'manager')
             or public.fn_can_view_lead(organization_id, owner_user_id)))
  );


-- ---- métricas por responsável: índices + fn_attendant_metrics (migration 0037) ----
-- spec 13 §6. Índices dedicados (won/lost por owner na janela de closed_at;
-- conversas por assignee org-leading) + agregação SECURITY INVOKER (a RLS de
-- crm_leads/conversations define o escopo por atendente). Idempotente.

create index if not exists idx_crm_leads_org_status_closed_owner
  on public.crm_leads (organization_id, status, closed_at, owner_user_id)
  where closed_at is not null;

create index if not exists idx_conversations_org_assignee_assigned
  on public.conversations (organization_id, assigned_to_user_id, assigned_at)
  where assigned_to_user_id is not null;

create or replace function public.fn_attendant_metrics(
  p_org uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_owner uuid default null
) returns jsonb
language sql stable
set search_path = public
as $$
  with
  lead_agg as (
    select
      owner_user_id as user_id,
      count(*) filter (where status = 'won')  as won,
      count(*) filter (where status = 'lost') as lost
    from public.crm_leads
    where organization_id = p_org
      and status in ('won', 'lost')
      and closed_at >= p_from and closed_at < p_to
      and owner_user_id is not null
      and (p_owner is null or owner_user_id = p_owner)
    group by owner_user_id
  ),
  conv_agg as (
    select
      assigned_to_user_id as user_id,
      count(*) as conversations_handled
    from public.conversations
    where organization_id = p_org
      and assigned_to_user_id is not null
      and assigned_at >= p_from and assigned_at < p_to
      and (p_owner is null or assigned_to_user_id = p_owner)
    group by assigned_to_user_id
  ),
  ttfr as (
    select
      c.assigned_to_user_id as user_id,
      avg(extract(epoch from (fr.first_human_out - fr.first_in))) as avg_first_response_seconds
    from public.conversations c
    cross join lateral (
      select
        min(m.sent_at) filter (where m.direction = 'inbound') as first_in,
        min(m.sent_at) filter (
          where m.direction = 'outbound' and m.sent_by_user_id is not null
        ) as first_human_out
      from public.messages m
      where m.conversation_id = c.id
    ) fr
    where c.organization_id = p_org
      and c.assigned_to_user_id is not null
      and (p_owner is null or c.assigned_to_user_id = p_owner)
      and fr.first_in is not null
      and fr.first_human_out is not null
      and fr.first_human_out > fr.first_in
      and fr.first_human_out >= p_from and fr.first_human_out < p_to
    group by c.assigned_to_user_id
  ),
  attendant_ids as (
    select user_id from lead_agg
    union select user_id from conv_agg
    union select user_id from ttfr
  )
  select jsonb_build_object(
    'funnel', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'stage_id', s.id,
          'stage_name', s.name,
          'position', s.position,
          'count', coalesce(l.cnt, 0)
        ) order by s.position, s.name
      )
      from public.crm_stages s
      left join (
        select stage_id, count(*) as cnt
        from public.crm_leads
        where organization_id = p_org
          and status = 'open'
          and (p_owner is null or owner_user_id = p_owner)
        group by stage_id
      ) l on l.stage_id = s.id
      where s.organization_id = p_org
        and s.is_archived = false
    ), '[]'::jsonb),
    'attendants', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_id', a.user_id,
          'won', coalesce(la.won, 0),
          'lost', coalesce(la.lost, 0),
          'conversations_handled', coalesce(ca.conversations_handled, 0),
          'avg_first_response_seconds', tf.avg_first_response_seconds
        ) order by coalesce(la.won, 0) desc, a.user_id
      )
      from attendant_ids a
      left join lead_agg la on la.user_id = a.user_id
      left join conv_agg ca on ca.user_id = a.user_id
      left join ttfr tf on tf.user_id = a.user_id
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.fn_attendant_metrics(uuid, timestamptz, timestamptz, uuid) from public;
revoke execute on function public.fn_attendant_metrics(uuid, timestamptz, timestamptz, uuid) from anon;
grant execute on function public.fn_attendant_metrics(uuid, timestamptz, timestamptz, uuid)
  to authenticated, service_role;


-- ---- webhooks universais + motor de regras (migration 0038) ----
-- Spec: docs/superpowers/specs/2026-07-17-webhooks-design.md. Idempotente
-- (create if not exists / drop policy if exists) — auto-curativo no update.sh.

create table if not exists public.webhook_sources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  path_token text not null unique,
  secret text,
  kind text not null default 'lead_capture' check (kind in ('lead_capture')),
  default_pipeline_id uuid not null references public.crm_pipelines(id) on delete cascade,
  default_stage_id uuid not null references public.crm_stages(id) on delete cascade,
  field_map jsonb not null default '{}'::jsonb,
  redirect_to text,
  is_active boolean not null default true,
  last_received_at timestamptz,
  created_by_user_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.automation_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  trigger_event text not null
    check (trigger_event ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  conditions jsonb not null default '[]'::jsonb,
  actions jsonb not null default '[]'::jsonb,
  is_active boolean not null default false,
  last_run_at timestamptz,
  run_count integer not null default 0,
  created_by_user_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_automation_rules_org_trigger
  on public.automation_rules (organization_id, trigger_event)
  where is_active;

create table if not exists public.automation_rule_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  rule_id uuid not null references public.automation_rules(id) on delete cascade,
  event_id uuid references public.event_log(id) on delete set null,
  status text not null check (status in ('success', 'partial', 'failed')),
  actions_result jsonb not null default '[]'::jsonb,
  error text,
  created_at timestamptz not null default now()
);

create index if not exists idx_automation_rule_runs_org_created
  on public.automation_rule_runs (organization_id, created_at desc);
create index if not exists idx_automation_rule_runs_rule
  on public.automation_rule_runs (rule_id, created_at desc);

alter table public.webhook_sources enable row level security;
alter table public.automation_rules enable row level security;
alter table public.automation_rule_runs enable row level security;

drop policy if exists "webhook_sources_select" on public.webhook_sources;
drop policy if exists "webhook_sources_manager_write" on public.webhook_sources;

create policy "webhook_sources_select" on public.webhook_sources
  for select using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

create policy "webhook_sources_manager_write" on public.webhook_sources
  using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  )
  with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  );

drop policy if exists "automation_rules_select" on public.automation_rules;
drop policy if exists "automation_rules_manager_write" on public.automation_rules;

create policy "automation_rules_select" on public.automation_rules
  for select using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

create policy "automation_rules_manager_write" on public.automation_rules
  using (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  )
  with check (
    public.fn_is_platform_admin()
    or ((organization_id in (select public.fn_user_org_ids()))
        and public.fn_role_at_least(organization_id, 'manager'))
  );

drop policy if exists "automation_rule_runs_select" on public.automation_rule_runs;

create policy "automation_rule_runs_select" on public.automation_rule_runs
  for select using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

-- ---- disponibilidade/horário por atendente: attendant_availability (migration 0039) ----
-- spec 13 §3.4/§5. Persiste o <AttendantStatusToggle> (spec 04 §8): is_available,
-- capacity (>0), schedule jsonb tz-aware, last_heartbeat_at (AT-08 auto-offline
-- 15min via worker TS). RLS por-comando (nunca FOR ALL): SELECT org-wide;
-- INSERT/UPDATE/DELETE = própria linha OU manager+. Idempotente.

create table if not exists public.attendant_availability (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  user_id           uuid not null references auth.users(id) on delete cascade,
  is_available      boolean not null default false,
  capacity          integer not null default 5 check (capacity > 0),
  schedule          jsonb not null default '{}',
  last_heartbeat_at timestamptz,
  updated_at        timestamptz not null default now(),
  unique (organization_id, user_id)
);

create index if not exists idx_attendant_availability_available
  on public.attendant_availability (organization_id)
  where is_available;

alter table public.attendant_availability enable row level security;

drop policy if exists "attendant_availability_select" on public.attendant_availability;
create policy "attendant_availability_select" on public.attendant_availability
  for select using (
    public.fn_is_platform_admin()
    or organization_id in (select public.fn_user_org_ids())
  );

drop policy if exists "attendant_availability_insert" on public.attendant_availability;
create policy "attendant_availability_insert" on public.attendant_availability
  for insert with check (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  );

drop policy if exists "attendant_availability_update" on public.attendant_availability;
create policy "attendant_availability_update" on public.attendant_availability
  for update using (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  ) with check (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  );

drop policy if exists "attendant_availability_delete" on public.attendant_availability;
create policy "attendant_availability_delete" on public.attendant_availability
  for delete using (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  );

-- ---- roteamento: disponibilidade/horário por atendente (migration 0039) ----
-- spec 13 §3.4/§5. attendant_availability (1 linha por org×user): toggle
-- online/offline + capacity ajustável + schedule tz-aware + last_heartbeat_at
-- (AT-08). RLS por-comando (nunca FOR ALL): SELECT org-wide; WRITE própria linha
-- OU manager+. settings.routing (§3.5) fica no jsonb organizations.settings,
-- validado por Zod (lib/schemas/routing.ts) — sem coluna nova. Idempotente.

create table if not exists public.attendant_availability (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references public.organizations(id) on delete cascade,
  user_id           uuid not null references auth.users(id) on delete cascade,
  is_available      boolean not null default false,
  capacity          integer not null default 5 check (capacity > 0),
  schedule          jsonb not null default '{}',
  last_heartbeat_at timestamptz,
  updated_at        timestamptz not null default now(),
  unique (organization_id, user_id)
);

create index if not exists idx_attendant_availability_available
  on public.attendant_availability (organization_id)
  where is_available;

alter table public.attendant_availability enable row level security;

drop policy if exists "attendant_availability_select" on public.attendant_availability;
create policy "attendant_availability_select" on public.attendant_availability
  for select using (
    public.fn_is_platform_admin()
    or organization_id in (select public.fn_user_org_ids())
  );

drop policy if exists "attendant_availability_insert" on public.attendant_availability;
create policy "attendant_availability_insert" on public.attendant_availability
  for insert with check (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  );

drop policy if exists "attendant_availability_update" on public.attendant_availability;
create policy "attendant_availability_update" on public.attendant_availability
  for update using (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  ) with check (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  );

drop policy if exists "attendant_availability_delete" on public.attendant_availability;
create policy "attendant_availability_delete" on public.attendant_availability
  for delete using (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and (user_id = auth.uid()
             or public.fn_role_at_least(organization_id, 'manager')))
  );


-- ---- roteamento: emissão de conversation.routing_requested (migration 0040) ----
-- AT-03: a ENTRADA de uma conversa na fila emite o evento; o worker (cron TS
-- lib/routing/worker.ts) consome e distribui. Trigger NUNCA faz HTTP — só
-- emit_event. ANTI-ECO: AFTER INSERT APENAS + WHEN sem-dono numa fila aberta;
-- não há trigger de UPDATE, então o UPDATE de atribuição do worker NUNCA re-emite
-- (sem isso ⇒ loop infinito). Idempotente (create or replace + drop if exists).
create or replace function public.fn_emit_conversation_routing() returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  perform public.emit_event(
    'conversation.routing_requested',
    'conversation',
    new.id,
    jsonb_build_object('conversation_id', new.id, 'organization_id', new.organization_id),
    '{}'::jsonb,
    new.organization_id
  );
  return null;
end;
$$;

alter function public.fn_emit_conversation_routing() owner to postgres;

drop trigger if exists trg_conversation_routing_requested on public.conversations;
create trigger trg_conversation_routing_requested
  after insert on public.conversations
  for each row
  when (new.assigned_to_user_id is null and new.status in ('open', 'pending'))
  execute function public.fn_emit_conversation_routing();


-- ---- cifragem at-rest dos secrets de webhooks (migration 0041) ----
-- Idempotente e auto-curativo (ver migrations/20260718150000_0041). Chave em
-- private.app_secrets (GUC como override); sem chave, plaintext é descartado com WARNING.
-- Forward-fix de raiz: fn_encrypt_oauth/fn_decrypt_oauth fixavam
-- search_path='public', mas pgcrypto vive no schema `extensions` no Supabase
-- (e faltava no baseline) — pgp_sym_* NUNCA resolvia. Garante a extensão e
-- recria as funções com o search_path correto.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Fonte da chave: Supabase cloud NÃO permite ALTER DATABASE/ROLE SET de GUC
-- custom (42501) — GUC-only nunca funcionaria lá. A chave vive em
-- private.app_secrets (schema sem grants; só as SECURITY DEFINER leem);
-- a GUC, quando setada (VPS/psql/testes), tem precedência como override.
create schema if not exists private;
create table if not exists private.app_secrets (
  name text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
revoke all on schema private from public;
revoke all on all tables in schema private from public;

create or replace function private.fn_oauth_key() returns text
    language sql security definer
    set search_path to 'private', 'pg_temp'
    as $$
  select coalesce(
    nullif(current_setting('app.nuvemshop_oauth_key', true), ''),
    (select value from private.app_secrets where name = 'nuvemshop_oauth_key')
  );
$$;
revoke all on function private.fn_oauth_key() from public;

create or replace function public.fn_encrypt_oauth(plaintext text) returns bytea
    language plpgsql security definer
    set search_path to 'public', 'private', 'extensions', 'pg_temp'
    as $$
declare
  k text := private.fn_oauth_key();
begin
  if k is null or length(k) < 32 then
    raise exception 'NUVEMSHOP_OAUTH_ENCRYPTION_KEY ausente';
  end if;
  return pgp_sym_encrypt(plaintext, k, 'cipher-algo=aes256');
end$$;

create or replace function public.fn_decrypt_oauth(ciphertext bytea) returns text
    language plpgsql security definer
    set search_path to 'public', 'private', 'extensions', 'pg_temp'
    as $$
declare
  k text := private.fn_oauth_key();
begin
  return pgp_sym_decrypt(ciphertext, k);
end$$;

revoke all on function public.fn_encrypt_oauth(text) from public;
revoke all on function public.fn_decrypt_oauth(bytea) from public;
grant execute on function public.fn_encrypt_oauth(text) to service_role;
grant execute on function public.fn_decrypt_oauth(bytea) to service_role;

alter table public.webhook_sources
  add column if not exists secret_encrypted bytea;

do $$
declare
  k text := current_setting('app.nuvemshop_oauth_key', true);
  has_plain boolean;
  n_dropped int;
begin
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'webhook_sources' and column_name = 'secret'
  ) into has_plain;
  if not has_plain then
    return; -- já migrado
  end if;

  if k is not null and length(k) >= 32 then
    update public.webhook_sources
      set secret_encrypted = public.fn_encrypt_oauth(secret)
      where secret is not null and secret_encrypted is null;
  else
    select count(*) into n_dropped from public.webhook_sources where secret is not null;
    if n_dropped > 0 then
      raise warning 'webhook_sources: % secret(s) plaintext descartado(s) — GUC app.nuvemshop_oauth_key ausente; re-configure os secrets pela UI', n_dropped;
    end if;
  end if;

  alter table public.webhook_sources drop column secret;
end$$;

-- automation_rules: reescreve configs de call_webhook trocando secret -> secret_enc
do $$
declare
  k text := current_setting('app.nuvemshop_oauth_key', true);
  r record;
  new_actions jsonb;
  a jsonb;
  n_dropped int := 0;
begin
  for r in
    select id, actions from public.automation_rules
    where actions::text like '%"secret"%'
  loop
    new_actions := '[]'::jsonb;
    for a in select * from jsonb_array_elements(r.actions) loop
      if a->>'type' = 'call_webhook' and (a->'config') ? 'secret' then
        if k is not null and length(k) >= 32 then
          a := jsonb_set(
            a #- '{config,secret}',
            '{config,secret_enc}',
            to_jsonb(encode(public.fn_encrypt_oauth(a#>>'{config,secret}'), 'hex'))
          );
        else
          a := a #- '{config,secret}';
          n_dropped := n_dropped + 1;
        end if;
      end if;
      new_actions := new_actions || jsonb_build_array(a);
    end loop;
    update public.automation_rules set actions = new_actions, updated_at = now()
      where id = r.id;
  end loop;
  if n_dropped > 0 then
    raise warning 'automation_rules: % secret(s) de call_webhook descartado(s) — GUC app.nuvemshop_oauth_key ausente; re-configure pela UI', n_dropped;
  end if;
end$$;


-- ---- trigger de leads sem duplicatas de evento (migration 0043) ----
-- Idempotente (create or replace + drop/create trigger). Ver migrations/20260718160001_0043.
create or replace function public.fn_emit_event_on_lead_change() returns trigger
    language plpgsql
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'INSERT' then
    -- lead.created é emitido pelo createLeadHandler (entity_kind='crm_lead').
    return new;
  end if;

  -- lead.stage_changed é emitido pelo moveLeadHandler (entity_kind='crm_lead').

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

-- INSERT não emite mais nada — dispara só em UPDATE.
drop trigger if exists trg_emit_event_on_lead_change on public.crm_leads;
create trigger trg_emit_event_on_lead_change
  after update on public.crm_leads
  for each row execute function public.fn_emit_event_on_lead_change();

-- Backlog morto: duplicatas antigas do trigger nunca terão consumer.
update public.event_log
  set status = 'done', updated_at = now()
  where status = 'pending'
    and entity_kind = 'lead'
    and event_type in ('lead.created', 'lead.stage_changed');

-- ---- RLS por role em crm_lead_activities/crm_lead_links (migration 0042) ----
-- G6-00 (INB-10): timeline/vínculos de lead seguiam org-flat no SELECT — agent em
-- modo 'own' não via o lead (0036) mas lia as activities/links dele por query direta.
-- FIX: SELECT das tabelas-filhas HERDA a visibilidade do lead-pai via a MESMA
-- fn_can_view_lead (0036), por EXISTS no lead_id (NÃO scalar de owner — lição G4-01:
-- scalar devolveria NULL pro lead oculto e own_and_unassigned trataria como fila ⇒
-- vazamento; o EXISTS fecha). WRITE fica org-scope IDÊNTICO ao de hoje (defesa em
-- profundidade, não o vetor: todo escritor real usa service role e bypassa RLS;
-- activities é append-only). crm_lead_links era FOR ALL (USING governa SELECT via OR,
-- a armadilha G4-01) — dropada e re-expressa POR-COMANDO. Idempotente, auto-curativo.

drop policy if exists "tenant_isolation_crm_lead_activities_select" on public.crm_lead_activities;
drop policy if exists "tenant_isolation_crm_lead_activities_insert" on public.crm_lead_activities;
drop policy if exists "crm_lead_activities_select" on public.crm_lead_activities;
drop policy if exists "crm_lead_activities_insert" on public.crm_lead_activities;

create policy "crm_lead_activities_select" on public.crm_lead_activities
  for select using (
    exists (
      select 1 from public.crm_leads l
      where l.id = crm_lead_activities.lead_id
        and public.fn_can_view_lead(l.organization_id, l.owner_user_id)
    )
  );

create policy "crm_lead_activities_insert" on public.crm_lead_activities
  for insert with check (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );

drop policy if exists "tenant_isolation_crm_lead_links_all" on public.crm_lead_links;
drop policy if exists "crm_lead_links_select" on public.crm_lead_links;
drop policy if exists "crm_lead_links_insert" on public.crm_lead_links;
drop policy if exists "crm_lead_links_update" on public.crm_lead_links;
drop policy if exists "crm_lead_links_delete" on public.crm_lead_links;

create policy "crm_lead_links_select" on public.crm_lead_links
  for select using (
    exists (
      select 1 from public.crm_leads l
      where l.id = crm_lead_links.lead_id
        and public.fn_can_view_lead(l.organization_id, l.owner_user_id)
    )
  );

create policy "crm_lead_links_insert" on public.crm_lead_links
  for insert with check (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );
create policy "crm_lead_links_update" on public.crm_lead_links
  for update using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  ) with check (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );
create policy "crm_lead_links_delete" on public.crm_lead_links
  for delete using (
    (organization_id in (select public.fn_user_org_ids()))
    or public.fn_is_platform_admin()
  );


-- ---- user_organizations SELECT org-wide para manager+ (migration 0044) ----
-- G6-06 (INB-14): manager passa a ler todo o roster da org (matriz spec 13 §4:
-- team=org:read a manager). Antes: só admin org-wide, manager caía no self-read
-- e GET /api/v1/team devolvia 1 linha. Self-read preservado p/ todos; WRITE
-- inalterado (insert/update/delete = admin). Idempotente e auto-curativo.
drop policy if exists "user_orgs_select" on public.user_organizations;
create policy "user_orgs_select" on public.user_organizations
  for select using (
    (user_id = auth.uid())
    or public.fn_role_at_least(organization_id, 'manager')
    or public.fn_is_platform_admin()
  );

-- ============================================================================
-- Dumps do Supabase zeram o search_path (set_config('search_path','',false));
-- os apêndices da fusão criam objetos NÃO-qualificados — restaura o público.
select pg_catalog.set_config('search_path', 'public, extensions', false);

-- APÊNDICE 0050_agent_harness (fusão Vendaval) — idempotente, espelho exato da
-- migration 20260719000000 (kit self-host aplica via install.sh/update.sh).
-- ============================================================================

-- 0050_agent_harness — schema do motor SDR (harness) portado do Vendaval para o
-- banco do CRM (fusão). Mapeamento canônico (lib/agent-engine/PORT-NOTES.md):
--   tenants → organizations · tenant_id → organization_id · leads → contacts ·
--   lead_id → contact_id · channel_session_id → FK real p/ channel_sessions(id).
-- Mortos no porte: tenants/leads (espelhos — o CRM é o mesmo banco agora),
-- event_inbox (o drain lê event_log direto), org_llm_credentials (BYOK do CRM =
-- ai_provider_credentials), colunas LGPD/handoff de leads (contacts.consent /
-- is_anonymized / conversations.bot_silenced_until já existem).
-- Idempotente (if not exists / or replace / do $$); SEM begin/commit; psql puro.

-- ============================================================================
-- Escalação humana do RUNTIME (ex-inbox_items do Vendaval; a UI lê daqui).
-- organization_id NULL = plataforma (ex.: infra) — visível só ao service role.
-- Kind já inclui 'judge_unaligned' (extensão da 0025 do Vendaval, embutida).
-- ============================================================================
create table if not exists agent_inbox_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,
  kind text not null check (kind in
    ('qr_rescan','job_dead','event_dead','budget_exceeded','handoff',
     'promotion_review','judge_unaligned','other')),
  severity text not null default 'warn' check (severity in ('info','warn','critical')),
  title text not null,
  body text,
  ref_kind text,
  ref_id uuid,
  status text not null default 'open' check (status in ('open','ack','resolved')),
  created_at timestamptz not null default now()
);
create index if not exists idx_agent_inbox_items_open on agent_inbox_items (organization_id, created_at desc)
  where status = 'open';

-- ============================================================================
-- 0002 — fila durável FOR UPDATE SKIP LOCKED com lane por contact_id.
-- ============================================================================
create table if not exists job_queue (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid references contacts(id) on delete cascade, -- NULL para watchdog/flywheel (jobs sem contato)
  kind text not null check (kind in ('inbound_turn','followup_turn','watchdog','flywheel')),
  source_event_id uuid,                -- event_log.id (CRM, mesmo banco) que originou o job — dedup evento→job
  payload jsonb not null default '{}',
  status text not null default 'pending'
    check (status in ('pending','running','done','failed','dead')),
  priority smallint not null default 100,
  run_after timestamptz not null default now(),
  attempts smallint not null default 0,
  max_attempts smallint not null default 5,
  last_error text,                     -- normalizado/truncado no código — nunca conteúdo de mensagem (PII)
  locked_by text,
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  -- jobs de turno TÊM contato; watchdog/flywheel NÃO — o schema força a coerência
  check ((kind in ('inbound_turn','followup_turn')) = (contact_id is not null))
);

create index if not exists idx_job_queue_claim on job_queue (status, run_after) where status = 'pending';

-- INVARIANTE (lane): 1 job 'running' por contato por vez; paralelismo entre contatos.
-- É o CINTO — o claim em duas etapas evita chegar aqui; na corrida residual o 23505
-- é capturado e o claim perde só a rodada.
create unique index if not exists uniq_job_queue_one_running_per_contact on job_queue (contact_id)
  where status = 'running' and contact_id is not null;

-- DEDUP evento→job: o handoff é at-least-once; evento re-entregue não vira 2º turno.
create unique index if not exists uniq_job_queue_source_event on job_queue (organization_id, source_event_id)
  where source_event_id is not null;

-- ============================================================================
-- 0003 — ledger de envio idempotente. Uma linha por mensagem `seq` do turno; `id`
-- É a idempotency_key da tentativa LÓGICA (re-attempt após 'failed' rotaciona o id).
-- ============================================================================
create table if not exists send_ledger (
  id uuid primary key default gen_random_uuid(), -- a idempotency_key da tentativa lógica corrente
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid references contacts(id) on delete cascade,
  job_id uuid not null references job_queue(id) on delete cascade,
  seq smallint not null,
  -- sha256 hex do corpo — PII (o corpo em si) NUNCA entra no ledger nem em log.
  body_hash text not null,
  -- requested: inserido imediatamente antes do envio (crash aqui → retry re-envia a MESMA key)
  -- accepted:  envio confirmado ('sent') — retry pula
  -- queued:    aceito e retido (sessão ≠ WORKING / waha_not_configured)
  -- vetoed:    is_blocked — veto permanente de negócio (irrevogável)
  -- failed:    'failed' (sem telefone / erro WAHA) — retry = tentativa lógica nova
  status text not null default 'requested'
    check (status in ('requested','accepted','queued','vetoed','failed')),
  crm_message_id uuid,                 -- messages.id (mesmo banco; vem na resposta do handler de envio)
  last_error text,                     -- normalizado/truncado no código — nunca corpo de mensagem (PII)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 1 linha por mensagem do turno — a base do "intenção exactly-once".
  unique (job_id, seq)
);

-- O throttle/spinning da cadeia before_send consulta envios recentes por org.
create index if not exists idx_send_ledger_recent on send_ledger (organization_id, created_at desc);

-- ============================================================================
-- Imutabilidade compartilhada das tabelas *_versions: conteúdo publicado é
-- imutável — mudança = versão nova; rollback = mover o ponteiro. DELETE fica de
-- fora de propósito (o cascade de organizations precisa passar; versão apontada
-- é protegida pelo FK do ponteiro correspondente).
-- ============================================================================
create or replace function fn_agent_versions_immutable() returns trigger
language plpgsql as $fn$
begin
  raise exception '% é imutável: mudança = versão nova; rollback = mover o ponteiro (%)',
    tg_table_name, replace(tg_table_name, '_versions', '_pointers');
end;
$fn$;

-- ============================================================================
-- 0004 — playbook em camadas versionado + carga por ponteiro. 1 linha por CAMADA
-- (platform|tenant|campaign); o runtime carrega por ponteiro no início de cada
-- run: trocar versão/rollback = mover ponteiro, sem restart. Camada platform é
-- global (organization_id NULL); tenant/campaign pertencem a uma org.
-- ============================================================================
create table if not exists playbook_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade, -- NULL = plataforma (global)
  layer text not null check (layer in ('platform', 'tenant', 'campaign')),
  -- Markdown com seções nomeadas (## ...), máx. 200 linhas por camada — validado no insert.
  content text not null,
  created_at timestamptz not null default now(),
  -- platform é global; tenant/campaign SEMPRE têm dono — o schema força a coerência
  check ((layer = 'platform') = (organization_id is null))
);

drop trigger if exists trg_playbook_versions_immutable on playbook_versions;
create trigger trg_playbook_versions_immutable
  before update on playbook_versions
  for each row execute function fn_agent_versions_immutable();

-- Ponteiro → versão ativa por escopo. SEM cascade no version_id: versão apontada
-- não pode sumir debaixo do ponteiro.
create table if not exists playbook_pointers (
  organization_id uuid references organizations(id) on delete cascade, -- NULL = plataforma (global)
  layer text not null check (layer in ('platform', 'tenant', 'campaign')),
  version_id uuid not null references playbook_versions(id),
  updated_at timestamptz not null default now(),
  check ((layer = 'platform') = (organization_id is null))
);

-- Unicidade do escopo (PK não serve: organization_id é NULL na plataforma).
create unique index if not exists uniq_playbook_pointers_org
  on playbook_pointers (organization_id, layer) where organization_id is not null;
create unique index if not exists uniq_playbook_pointers_platform
  on playbook_pointers (layer) where organization_id is null;

-- ============================================================================
-- 0005 + 0012 — espelho de saúde da sessão WAHA + circuito de saúde do número.
-- status_changed_at só avança quando o status MUDA (métrica "tempo no estado").
-- Os holds de status e de saúde coexistem — job retido sob QUALQUER hold.
-- ============================================================================
create table if not exists channel_session_health (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  channel_session_id uuid not null references channel_sessions(id) on delete cascade,
  status text not null,
  status_changed_at timestamptz not null default now(),
  -- Status já escalado (agent_inbox_items kind='qr_rescan') no EPISÓDIO corrente —
  -- dedup do "exatamente 1×". Volta a null quando a sessão volta a WORKING.
  escalated_status text,
  -- Circuito de saúde (0012): default false — linhas criadas pelo watchdog NÃO
  -- nascem health-held; o "nasce em hold" (fail-safe de go-live) é decidido pelo
  -- tick de saúde quando health_released_at is null, nunca pelo default.
  health_hold_active boolean not null default false,
  health_hold_reason text,          -- 'go_live' | 'block_rate' | 'response_rate'
  health_held_at timestamptz,       -- início do episódio de hold (base do cool-down)
  -- Liberação explícita inicial (go-live). NULL = número novo, nunca liberado →
  -- nasce em hold (fail-safe). Uma vez setado, permanece.
  health_released_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (organization_id, channel_session_id)
);

-- Cursor durável de consumo do event_log do CRM por consumidor do harness (o
-- watchdog é o 1º). Tabela de PLATAFORMA (sem org): RLS habilitada sem policy —
-- só o service role (worker) lê/escreve.
create table if not exists watchdog_cursors (
  consumer text primary key,
  last_created_at timestamptz not null default 'epoch',
  last_event_id uuid not null default '00000000-0000-0000-0000-000000000000',
  updated_at timestamptz not null default now()
);

-- ============================================================================
-- 0006 — toda chamada de modelo (custo, cache, atribuição); agregado mensal =
-- enforcement do budget. Credenciais BYOK são do CRM (ai_provider_credentials) —
-- org_llm_credentials do Vendaval NÃO foi portada.
-- ============================================================================
create table if not exists llm_calls (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid references contacts(id) on delete set null,
  job_id uuid references job_queue(id) on delete set null,
  variant_id uuid,                       -- experiment_variants (flywheel); nasce p/ atribuição
  purpose text not null default 'agent_turn',  -- 'agent_turn' | 'classifier' | 'compaction' | 'connection_test'
  provider text not null,
  model text not null,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  cache_read_tokens int not null default 0,   -- métrica de 1ª classe
  cache_write_tokens int not null default 0,
  cost_cents numeric,                    -- null = preço desconhecido — nunca inventar 0
  latency_ms int,
  created_at timestamptz not null default now()
);
create index if not exists idx_llm_calls_org_time on llm_calls (organization_id, created_at);

-- ============================================================================
-- 0007 — artefato durável do loop do agente: cada run fecha escrevendo um
-- checkpoint; o run seguinte do MESMO contato abre lendo o mais recente —
-- sessões descartáveis, artefatos duráveis. Conteúdo validado por Zod no handler.
-- ============================================================================
create table if not exists lead_checkpoints (
  id uuid primary key default gen_random_uuid(),
  -- ordem de escrita estrita (created_at pode empatar) — abertura lê por seq.
  seq bigint generated always as identity,
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id) on delete cascade,
  job_id uuid references job_queue(id) on delete set null, -- o run É o job
  commitments jsonb not null default '[]',      -- string[] — compromissos assumidos no turno
  objections jsonb not null default '[]',       -- string[] — objeções levantadas
  next_action text,
  rolling_summary text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists idx_lead_checkpoints_latest
  on lead_checkpoints (organization_id, contact_id, seq desc);

-- ============================================================================
-- 0008 — estado do funil por contato. O modelo MARCA avanços via tool; quem
-- valida a transição é a máquina de estados NO CÓDIGO — o CHECK é backstop.
-- ============================================================================
create table if not exists lead_state (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id) on delete cascade,
  stage text not null default 'new' check (stage in
    ('new','contacted','qualifying','qualified','negotiating','won','lost')),
  -- qualificação whitelisted (BANT) — Zod .strict() rejeita outras chaves antes daqui.
  qualification jsonb not null default '{}',
  next_action text,
  updated_at timestamptz not null default now(),
  unique (organization_id, contact_id)
);

-- Histórico append-only de transições — auditoria/diffabilidade do funil.
create table if not exists lead_state_transitions (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id) on delete cascade,
  job_id uuid references job_queue(id) on delete set null,
  from_stage text not null,
  to_stage text not null,
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists idx_lead_state_transitions_contact
  on lead_state_transitions (organization_id, contact_id, seq desc);

-- ============================================================================
-- 0009 — métricas de 1ª classe persistidas. Labels SÓ com ids/contagens — PII
-- jamais entra. organization_id NULL = plataforma.
-- ============================================================================
create table if not exists metrics (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade, -- null = plataforma
  name text not null,
  labels jsonb not null default '{}',
  value double precision not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_metrics_name_time on metrics (name, created_at desc);
create index if not exists idx_metrics_org_name_time on metrics (organization_id, name, created_at desc);

-- ============================================================================
-- 0010 + 0011 + 0012 — knobs anti-ban por número/sessão + ledger de pacing.
-- Coluna NULL = default conservador no código (knobs, nunca constantes). O cap
-- diário ABSOLUTO não mora aqui: fonte única é channel_sessions.daily_message_limit.
-- ============================================================================
create table if not exists channel_knobs (
  organization_id uuid not null references organizations(id) on delete cascade,
  channel_session_id uuid not null references channel_sessions(id) on delete cascade,
  throttle_ms integer,                -- intervalo mínimo entre envios do número
  jitter_max_ms integer,              -- teto do jitter randômico somado ao throttle
  window_start_hour smallint,         -- janela [start, end) na hora local da org
  window_end_hour smallint,
  allow_sunday boolean,               -- NULL = default do código (hoje: enviar)
  timezone text,                      -- IANA tz da org (a janela é avaliada nela)
  -- degraus [{"minAgeDays":N,"cap":M|null}, ...]; CHECK (array NÃO-VAZIO) +
  -- validação de shape no load — NULL cai no default; `[]` é rejeitado.
  warmup_daily_caps jsonb
    constraint channel_knobs_warmup_caps_is_array
    check (
      warmup_daily_caps is null
      or (jsonb_typeof(warmup_daily_caps) = 'array' and jsonb_array_length(warmup_daily_caps) > 0)
    ),
  -- knobs de spinning / saúde (0011/0012): CHECK só garante "é objeto"; campo a
  -- campo é validado no load. NULL ou shape inválido → defaults conservadores.
  spinning_knobs jsonb
    constraint channel_knobs_spinning_is_object
    check (spinning_knobs is null or jsonb_typeof(spinning_knobs) = 'object'),
  health_knobs jsonb
    constraint channel_knobs_health_is_object
    check (health_knobs is null or jsonb_typeof(health_knobs) = 'object'),
  number_activated_at timestamptz not null default now(), -- idade do número p/ warm-up
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, channel_session_id)
);

-- Ledger de envios efetivados por número — estado durável do throttle e dos caps
-- diários (na tz da org).
create table if not exists pacing_ledger (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  channel_session_id uuid not null references channel_sessions(id) on delete cascade,
  sent_at timestamptz not null default now()
);
create index if not exists idx_pacing_ledger_session
  on pacing_ledger (organization_id, channel_session_id, sent_at desc);

-- 0011 — janela deslizante de copies enviadas (gate anti-template-idêntico):
-- copy NORMALIZADA das últimas outbound por NÚMERO (across contatos).
create table if not exists outbound_copies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  channel_session_id uuid not null references channel_sessions(id) on delete cascade,
  normalized_text text not null,      -- copy normalizada (lower/trim/whitespace) p/ similaridade
  normalized_hash text not null,      -- sha256 do normalizado p/ igualdade exata
  sent_at timestamptz not null default now()
);
create index if not exists idx_outbound_copies_session
  on outbound_copies (organization_id, channel_session_id, sent_at desc);

-- ============================================================================
-- 0013 — cron persistente POR CONTATO. Irmão da fila: a fila processa AGORA, o
-- cron AGENDA e, no disparo, ENFILEIRA um job em job_queue. Sobrevive a restart
-- porque TODO o estado mora aqui.
-- ============================================================================
create table if not exists cron_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id) on delete cascade,
  kind text not null check (kind in ('at','every','cron')),
  --   'at'   → one-shot: next_run_at guarda o instante; dispara e desabilita.
  --   'every'→ recorrência fixa: interval_ms é o período (ms).
  --   'cron' → expressão 5-campos avaliada em tz (IANA).
  interval_ms bigint check (interval_ms is null or interval_ms > 0),
  cron_expr text,
  tz text not null default 'UTC',
  -- o que enfileirar quando disparar; coerência kind⇔contato é do CHECK de
  -- job_queue no enqueue — cron mal-configurado falha PERMANENTE (23514), nunca
  -- silenciosamente.
  job_kind text not null default 'followup_turn'
    check (job_kind in ('inbound_turn','followup_turn','watchdog','flywheel')),
  payload jsonb not null default '{}',
  -- próximo disparo — JÁ com o offset de stagger determinístico (anti-rajada).
  next_run_at timestamptz not null,
  enabled boolean not null default true,
  -- retry do disparo CORRENTE: transiente incrementa + adia (backoff); esgotar
  -- max_attempts desabilita + agent_inbox_items.
  attempts smallint not null default 0,
  max_attempts smallint not null default 5,
  last_error text,                        -- normalizado/truncado — nunca PII
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'every' or interval_ms is not null),
  check (kind <> 'cron' or cron_expr is not null)
);
create index if not exists idx_cron_jobs_due on cron_jobs (next_run_at)
  where enabled = true;

-- ============================================================================
-- 0014 — templates de re-entrada versionados + ponteiro. Uma versão guarda N
-- VARIANTES pt-br de spinning; a re-entrada determinística envia a variante
-- DIRETO pela cadeia de guardrails, sem LLM — custo $0.
-- ============================================================================
create table if not exists reentry_template_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  variants text[] not null check (array_length(variants, 1) >= 1),
  created_at timestamptz not null default now()
);

drop trigger if exists trg_reentry_template_versions_immutable on reentry_template_versions;
create trigger trg_reentry_template_versions_immutable
  before update on reentry_template_versions
  for each row execute function fn_agent_versions_immutable();

create table if not exists reentry_template_pointers (
  organization_id uuid primary key references organizations(id) on delete cascade,
  version_id uuid not null references reentry_template_versions(id),
  updated_at timestamptz not null default now()
);

-- ============================================================================
-- 0015 + 0016 — memória durável por contato. O ÍNDICE (headlines) é injetado no
-- sufixo do prompt com orçamento fixo; o CORPO vem sob demanda. Hard cap imposto
-- na ESCRITA (recusa nota que estouraria) — sem truncamento silencioso.
-- Nota de um contato NUNCA aparece em run de outro (query sempre filtra
-- organization_id + contact_id de fonte confiável).
-- ============================================================================
create table if not exists lead_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  contact_id uuid not null references contacts(id) on delete cascade,
  headline text not null check (length(headline) > 0), -- a LINHA do índice
  body text not null check (length(body) > 0),         -- corpo sob demanda
  -- 0016: vetor derivado p/ recall híbrido. jsonb (array de floats), não pgvector:
  -- a DIMENSÃO é do provedor (BYOK agnóstico) e o conjunto por contato é pequeno
  -- (hard cap) ⇒ cosseno exato em app, sem índice ANN. Populado preguiçosamente;
  -- notas são write-once ⇒ o embedding cacheado nunca fica stale.
  embedding jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_lead_notes_contact
  on lead_notes (organization_id, contact_id, created_at);

-- ============================================================================
-- 0017 — playbooks SITUACIONAIS como skills versionadas com disclosure
-- progressivo: só name+description (o ÍNDICE) reside no prompt; o body carrega
-- SÓ quando o matcher if-then DETERMINÍSTICO dispara. platform = global
-- (organization_id NULL, ex.: "STOP ambíguo"/compliance).
-- ============================================================================
create table if not exists skill_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade, -- NULL = plataforma (global)
  name text not null check (length(name) > 0),
  description text not null check (length(description) > 0),
  body text not null check (length(body) > 0), -- markdown ≤200 linhas; carrega SÓ no match
  -- { "any_keywords": string[], "probe_keywords"?: string[] } — shape validado no código.
  matcher jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

drop trigger if exists trg_skill_versions_immutable on skill_versions;
create trigger trg_skill_versions_immutable
  before update on skill_versions
  for each row execute function fn_agent_versions_immutable();

create table if not exists skill_pointers (
  organization_id uuid references organizations(id) on delete cascade, -- NULL = plataforma (global)
  name text not null check (length(name) > 0),
  version_id uuid not null references skill_versions(id),
  updated_at timestamptz not null default now()
);
create unique index if not exists uniq_skill_pointers_org
  on skill_pointers (organization_id, name) where organization_id is not null;
create unique index if not exists uniq_skill_pointers_platform
  on skill_pointers (name) where organization_id is null;

-- ============================================================================
-- 0018 — tabela de preços/promessas versionada por ponteiro (anti-"vendo por
-- R$1"): o gate before_send carrega por ponteiro sob o lock de cada tentativa.
-- ============================================================================
create table if not exists promise_table_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  -- { minPriceCents?, maxDiscountPercent?, maxInstallments? } — shape validado no
  -- insert. Campo ausente = dimensão não fiscalizada.
  values jsonb not null,
  created_at timestamptz not null default now()
);

drop trigger if exists trg_promise_table_versions_immutable on promise_table_versions;
create trigger trg_promise_table_versions_immutable
  before update on promise_table_versions
  for each row execute function fn_agent_versions_immutable();

create table if not exists promise_table_pointers (
  organization_id uuid not null references organizations(id) on delete cascade,
  version_id uuid not null references promise_table_versions(id),
  updated_at timestamptz not null default now()
);
create unique index if not exists uniq_promise_table_pointers_org
  on promise_table_pointers (organization_id);

-- ============================================================================
-- 0019 — template de disclosure "assistente virtual" versionado por ponteiro
-- (disclosure by design — CDC hoje / PL 2338 amanhã). Injetado na 1ª mensagem
-- (modo inject) ou exigido do modelo (modo veto).
-- ============================================================================
create table if not exists disclosure_template_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  body text not null, -- texto pt-br do disclosure
  created_at timestamptz not null default now()
);

drop trigger if exists trg_disclosure_template_versions_immutable on disclosure_template_versions;
create trigger trg_disclosure_template_versions_immutable
  before update on disclosure_template_versions
  for each row execute function fn_agent_versions_immutable();

create table if not exists disclosure_template_pointers (
  organization_id uuid not null references organizations(id) on delete cascade,
  version_id uuid not null references disclosure_template_versions(id),
  updated_at timestamptz not null default now()
);
create unique index if not exists uniq_disclosure_template_pointers_org
  on disclosure_template_pointers (organization_id);

-- ============================================================================
-- 0021 — trace de auditoria da cadeia before_send por tentativa: array de gates
-- avaliados + gate/código do veto (null = passou). Escrita autônoma (fora da tx
-- serializada) — a auditoria do veto SOBREVIVE ao rollback. PII fora: só
-- gate/verdict/code/detail — o CORPO da mensagem NUNCA entra aqui.
-- ============================================================================
create table if not exists before_send_traces (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  job_id uuid not null references job_queue(id) on delete cascade, -- RUN = job_queue.id
  contact_id uuid references contacts(id) on delete cascade,
  channel_session_id uuid not null references channel_sessions(id) on delete cascade,
  -- GateTraceEntry[]: [{ gate, verdict, code?, detail? }, ...] — sem PII.
  trace jsonb not null,
  vetoed_gate text,
  vetoed_code text,
  created_at timestamptz not null default now()
);
create index if not exists idx_before_send_traces_run
  on before_send_traces (organization_id, job_id, created_at);

-- ============================================================================
-- 0023 — vereditos dos judges em produção, batch offline (NUNCA inline por
-- mensagem). Idempotente/resumível: unique (dataset, trace_id, dimension) +
-- on conflict do nothing. PII fora do DB: só metadata/proveniência anonimizada.
-- ============================================================================
create table if not exists flywheel_judge_verdicts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  dataset text not null,               -- namespace da proveniência (replay)
  trace_id text not null,
  dimension text not null,
  verdict text not null check (verdict in ('yes', 'no', 'unknown')),
  option_order text not null,          -- auditoria da mitigação de position bias
  judge_family text not null,
  model text not null,
  -- ORIGEM do trace: proveniência do dataset (replay) ou playbook_version (live).
  provenance jsonb not null default '{}',
  run_id uuid not null,                -- agrupa uma RODADA de batch
  judged_at timestamptz not null default now()
);
create unique index if not exists uq_flywheel_judge_verdicts_key
  on flywheel_judge_verdicts (dataset, trace_id, dimension);
create index if not exists idx_flywheel_judge_verdicts_run
  on flywheel_judge_verdicts (organization_id, run_id);
create index if not exists idx_flywheel_judge_verdicts_dataset
  on flywheel_judge_verdicts (dataset, dimension);

-- ============================================================================
-- 0024 — CANDIDATOS de melhoria propostos pelo distiller isolado. NUNCA aplica:
-- aplicar é o merge sob gate humano. Este é o ÚNICO store de escrita do distiller
-- (anti "curator-takeover"). Cada proposta REFERENCIA a evidência que a motivou.
-- ============================================================================
create table if not exists flywheel_distiller_proposals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  run_id uuid not null,
  dataset text not null,
  type text not null check (type in ('playbook_bullet', 'golden_case', 'reentry_trigger')),
  target text not null,                -- camada de playbook / arquivo golden / família de gatilho
  content text not null check (length(content) > 0), -- texto proposto, pt-br, sem PII
  evidence jsonb not null,             -- trace_ids + run_ids + taxa/amostra
  proposed_at timestamptz not null default now()
);
create index if not exists idx_flywheel_distiller_proposals_run
  on flywheel_distiller_proposals (organization_id, run_id);
create index if not exists idx_flywheel_distiller_proposals_dataset
  on flywheel_distiller_proposals (dataset, type);

-- ============================================================================
-- 0025 — MANUTENÇÃO do judge: rotaciona casos frescos julgados em produção para
-- um POOL de alinhamento (candidatos a novo lote de labels humanos no drift).
-- A unique é o DEDUP da rotação. (A extensão de kind 'judge_unaligned' já está
-- embutida no CHECK de agent_inbox_items acima.)
-- ============================================================================
create table if not exists judge_alignment_pool (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  dataset text not null,
  trace_id text not null,
  dimension text not null,
  added_at timestamptz not null default now()
);
create unique index if not exists uq_judge_alignment_pool_key
  on judge_alignment_pool (dataset, trace_id, dimension);
create index if not exists idx_judge_alignment_pool_dim
  on judge_alignment_pool (organization_id, dimension);

-- ============================================================================
-- 0026 — knobs de re-entrada (timing de follow-up + segmentação) versionados +
-- ponteiro. O 1º alvo concreto do flywheel: timing não é constante nem env —
-- é config versionada por org, otimizável e rollbackável pelo ponteiro.
-- ============================================================================
create table if not exists reentry_knob_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  -- { follow_up_window_hours: number>0, enabled_segments: string[] } — shape
  -- revalidado no insert.
  knobs jsonb not null,
  created_at timestamptz not null default now()
);

drop trigger if exists trg_reentry_knob_versions_immutable on reentry_knob_versions;
create trigger trg_reentry_knob_versions_immutable
  before update on reentry_knob_versions
  for each row execute function fn_agent_versions_immutable();

create table if not exists reentry_knob_pointers (
  organization_id uuid primary key references organizations(id) on delete cascade,
  version_id uuid not null references reentry_knob_versions(id),
  updated_at timestamptz not null default now()
);

-- ============================================================================
-- RLS — padrão do repo: tenant_isolation_<tabela>_all via fn_user_org_ids() +
-- revoke de anon. Nas tabelas com organization_id nullable (agent_inbox_items,
-- playbook_versions/pointers, skill_versions/pointers, metrics) a MESMA policy
-- serve: `null in (...)` nunca é true ⇒ linhas de plataforma são visíveis só ao
-- service role (que bypassa RLS).
--
-- A enumeração que morava AQUI virou a função sem parâmetro logo abaixo
-- (migration 0325) — ela é chamada em cada um dos três pontos onde havia laço,
-- e de novo no fim do arquivo.
-- ============================================================================

-- ---- proteções de tabela de organização: o laço vira função (migration 0325) ----
--
-- ADR-0002, D5: "Essas rotinas saem do laço do baseline para funções sem
-- parâmetro, chamadas pelo baseline e pela provisionadora." É a irmã da 0274 —
-- lá foram as travas do suporte, aqui são RLS ligada, `revoke all … from anon` e
-- o isolamento por organização.
--
-- A RÉGUA É `not relrowsecurity`, e não "toda tabela com organization_id".
-- Medido no baseline de ed42ad119 (pg17 descartável, ON_ERROR_STOP=1): das 119
-- tabelas de organização, 0 estão sem RLS — então esta varredura é no-op aqui —,
-- mas 49 ainda têm privilégio de `anon`, 8 são server-only (RLS ligada e ZERO
-- policies, de propósito) e 66 não têm a policy ampla. Varrer as 119 abriria as
-- 8 e atropelaria as policies por papel das 66. Já uma tabela recém-criada — o
-- que a provisionadora de um módulo produz — nasce com RLS desligada, e é
-- exatamente ela que esta régua pega. O racional inteiro está no cabeçalho da
-- migration 20260919153000_0325_*.sql.
--
-- Idempotente: `drop policy if exists` antes do `create policy`; reaplicar
-- converge. A definição fica AQUI, antes da varredura de anon (que é, de
-- propósito, quem cura o `anon` de toda função nova); a CHAMADA fica no fim do
-- arquivo, junto com a da 0274.

create or replace function public.fn_proteger_tabelas_de_organizacao()
returns void
language plpgsql
set search_path = public
as $f$
declare r record;
begin
 for r in
   select c.relname
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relrowsecurity
      and exists (
        select 1 from pg_attribute a
         where a.attrelid = c.oid
           and a.attname = 'organization_id'
           and a.attnum > 0
           and not a.attisdropped)
    order by c.relname
 loop
   execute format('alter table public.%I enable row level security', r.relname);
   execute format('revoke all on public.%I from anon', r.relname);
   execute format('drop policy if exists tenant_isolation_%s_all on public.%I', r.relname, r.relname);
   execute format(
     'create policy tenant_isolation_%s_all on public.%I for all
        using (organization_id in (select * from public.fn_user_org_ids()))
        with check (organization_id in (select * from public.fn_user_org_ids()))',
     r.relname, r.relname);
 end loop;
end $f$;

-- O ponto de entrada que a provisionadora de um módulo chama no FIM do corpo,
-- na MESMA transação em que criou as tabelas. A ORDEM importa: as travas do
-- suporte (0274) leem o privilégio de `authenticated` de cada tabela para
-- decidir entre as três policies restritivas e o contrato server-only, então
-- vêm DEPOIS de a RLS e o isolamento estarem no lugar.
create or replace function public.fn_proteger_modulo_provisionado()
returns void
language plpgsql
set search_path = public
as $f$
begin
  perform public.fn_proteger_tabelas_de_organizacao();
  perform public.fn_aplicar_travas_de_suporte();
end $f$;

revoke execute on function public.fn_proteger_tabelas_de_organizacao() from public, anon, authenticated, service_role;
revoke execute on function public.fn_proteger_modulo_provisionado() from public, anon, authenticated, service_role;


-- A rotina da migration 0325 no lugar do laço enumerado: ela varre o catálogo
-- procurando tabela de organização com RLS DESLIGADA, que neste ponto do arquivo
-- é exatamente o conjunto que a lista enumerava (medido, tabela a tabela).
do $$ begin perform public.fn_proteger_tabelas_de_organizacao(); end $$;

-- watchdog_cursors não tem organization_id (infra de plataforma): RLS habilitada
-- SEM policy ⇒ só o service role acessa.
alter table watchdog_cursors enable row level security;
revoke all on watchdog_cursors from anon;


-- APÊNDICE 0051_agent_version_immutability (fusão Fase 2B) — espelho exato da migration.

-- 0051_agent_version_immutability — Fase 2B da fusão Vendaval.
--
-- ai_agent_versions passa a ser a fonte de config que o agent-engine LÊ POR
-- PONTEIRO no início de cada turno (published_version_id). Uma versão publicada
-- precisa ser imutável NO BANCO (não só por convenção de app): editar = criar
-- versão draft nova; rollback = revert (clona + publica). Mesmo princípio do
-- fn_agent_versions_immutable do harness (0050), adaptado ao lifecycle desta
-- tabela — o UPDATE de CONTEÚDO é vetado fora de status='draft'; as transições
-- de lifecycle (draft→published→superseded→archived + timestamps) continuam
-- livres (é o que o RPC fn_publish_ai_agent_version faz).
-- Idempotente; sem BEGIN/COMMIT; psql puro.

create or replace function fn_ai_agent_version_content_immutable() returns trigger
language plpgsql as $fn$
begin
  -- Conteúdo congelado fora de draft. Campos de lifecycle ficam de fora do
  -- veto de propósito: status/published_at/superseded_at mudam no publish.
  if old.status <> 'draft' and (
       new.system_prompt          is distinct from old.system_prompt
    or new.provider               is distinct from old.provider
    or new.model                  is distinct from old.model
    or new.credential_id          is distinct from old.credential_id
    or new.tool_ids               is distinct from old.tool_ids
    or new.trigger_config         is distinct from old.trigger_config
    or new.channel_session_id     is distinct from old.channel_session_id
    or new.max_steps              is distinct from old.max_steps
    or new.token_budget           is distinct from old.token_budget
    or new.cost_budget_cents      is distinct from old.cost_budget_cents
    or new.history_message_window is distinct from old.history_message_window
    or new.history_token_window   is distinct from old.history_token_window
    or new.handoff_keywords       is distinct from old.handoff_keywords
    or new.handoff_tool_enabled   is distinct from old.handoff_tool_enabled
    or new.version_number         is distinct from old.version_number
    or new.agent_id               is distinct from old.agent_id
    or new.organization_id        is distinct from old.organization_id
  ) then
    raise exception 'ai_agent_versions % é imutável (status=%): mudança de conteúdo = versão draft nova; rollback = revert (clona + publica)',
      old.id, old.status;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_ai_agent_versions_content_immutable on public.ai_agent_versions;
create trigger trg_ai_agent_versions_content_immutable
  before update on public.ai_agent_versions
  for each row execute function fn_ai_agent_version_content_immutable();


-- APÊNDICE 0052_republish_fn_uppercase_fix — re-assenta a fn de publish correta (anti-drift).

-- 0052_republish_fn_uppercase_fix — forward-fix de DRIFT de função.
--
-- Sintoma (Fase 2B da fusão): publish na tela falhava com channel_session_offline
-- mesmo com a sessão WORKING. Diagnóstico no banco hospedado: a função
-- fn_publish_ai_agent_version deployada continha `v_session.status <> 'working'`
-- (minúsculo) — a versão PRÉ-0026 — apesar de 20260706200000_0026 constar como
-- aplicada em schema_migrations. Ou seja: algo re-aplicou a definição antiga por
-- FORA do fluxo de migrations depois da 0026 (drift).
-- Conserto: re-assentar a definição correta da 0026 como migration NOVA (forward-
-- fix; migração aplicada nunca é editada). Idempotente por natureza (or replace).

create or replace function public.fn_publish_ai_agent_version(
  p_org_id uuid,
  p_agent_id uuid,
  p_version_id uuid
)
returns table (
  agent_id uuid,
  version_id uuid,
  previous_version_id uuid,
  published_at timestamptz
)
language plpgsql
security definer
set search_path to 'public'
as $$
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
         v.credential_id, v.channel_session_id, v.provisioning_origin
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
  if p_expected_provenance is not null and (
    p_expected_provenance not in('onboarding','legacy_reconciliation') or
    v_version.provisioning_origin is distinct from p_expected_provenance or
    (select count(*) from public.ai_agent_versions own_version where own_version.organization_id=p_org_id and own_version.agent_id=p_agent_id)<>1
  ) then raise exception 'existing_version_requires_review' using errcode='P0001';end if;
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

comment on function public.fn_publish_ai_agent_version(uuid, uuid, uuid) is
  'EPIC-13 S-13.06 (fixed in 0026): compares channel_sessions.status against WORKING (uppercase), matching channel_sessions_status_check. 0024/0025 compared against lowercase working and always raised channel_session_offline.';

-- ============================================================================
-- 0053 — Operação Visível F3: rastro de aplicação de proposta do flywheel
-- (applied_at/applied_version_id/applied_by; null = pendente). Idempotente.
-- ============================================================================
alter table flywheel_distiller_proposals
  add column if not exists applied_at timestamptz,
  add column if not exists applied_version_id uuid references ai_agent_versions(id) on delete set null,
  add column if not exists applied_by uuid;

-- ---- followup flows (migration 0054) ----

create table if not exists followup_flow_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  graph jsonb not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists followup_flow_pointers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  status text not null default 'draft' check (status in ('draft','active','disabled')),
  active_version_id uuid references followup_flow_versions(id),
  draft_graph jsonb,
  handoff_policy text not null default 'pause' check (handoff_policy in ('pause','cancel','allow')),
  trigger_config jsonb not null default '{"kind":"manual"}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

create table if not exists followup_enrollments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  pointer_id uuid not null references followup_flow_pointers(id) on delete cascade,
  version_id uuid not null references followup_flow_versions(id),
  contact_id uuid not null references contacts(id) on delete cascade,
  conversation_id uuid references conversations(id) on delete set null,
  current_node_id text not null,
  status text not null default 'active'
    check (status in ('active','waiting_reply','paused_handoff','completed','cancelled','dead')),
  next_eval_at timestamptz,
  claimed_until timestamptz,
  attempts smallint not null default 0,
  max_attempts smallint not null default 5,
  last_error text,
  steps_taken smallint not null default 0,
  outcome text check (outcome in ('converted','replied','exhausted','opted_out','handoff')),
  cancel_reason text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  -- estados com relógio TÊM next_eval_at; pausados/terminais NÃO — coerência no schema
  check (
    (status in ('active','waiting_reply') and next_eval_at is not null)
    or (status in ('paused_handoff','completed','cancelled','dead'))
  )
);

create index if not exists idx_followup_enrollments_due
  on followup_enrollments (next_eval_at)
  where status in ('active','waiting_reply');

create unique index if not exists idx_followup_enrollments_one_live
  on followup_enrollments (pointer_id, contact_id)
  where status in ('active','waiting_reply','paused_handoff');

create index if not exists idx_followup_enrollments_contact
  on followup_enrollments (organization_id, contact_id);

create table if not exists followup_enrollment_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  enrollment_id uuid not null references followup_enrollments(id) on delete cascade,
  node_id text,
  event_type text not null,
  payload jsonb not null default '{}',
  idempotency_key text,
  created_at timestamptz not null default now()
);

create unique index if not exists idx_followup_events_idem
  on followup_enrollment_events (enrollment_id, idempotency_key)
  where idempotency_key is not null;

-- RLS (padrão fn_user_org_ids)
alter table followup_flow_versions enable row level security;
alter table followup_flow_pointers enable row level security;
alter table followup_enrollments enable row level security;
alter table followup_enrollment_events enable row level security;

do $$ begin
  create policy tenant_isolation_followup_flow_versions_all on followup_flow_versions
    for all using (organization_id in (select fn_user_org_ids()))
    with check (organization_id in (select fn_user_org_ids()));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy tenant_isolation_followup_flow_pointers_all on followup_flow_pointers
    for all using (organization_id in (select fn_user_org_ids()))
    with check (organization_id in (select fn_user_org_ids()));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy tenant_isolation_followup_enrollments_all on followup_enrollments
    for all using (organization_id in (select fn_user_org_ids()))
    with check (organization_id in (select fn_user_org_ids()));
exception when duplicate_object then null; end $$;
do $$ begin
  create policy tenant_isolation_followup_enrollment_events_all on followup_enrollment_events
    for all using (organization_id in (select fn_user_org_ids()))
    with check (organization_id in (select fn_user_org_ids()));
exception when duplicate_object then null; end $$;

-- Claim atômico do worker (SKIP LOCKED) — service role only
create or replace function fn_claim_due_followup_enrollments(p_limit int, p_lease_seconds int)
returns setof followup_enrollments
language sql
security definer
set search_path = public
as $$
  update followup_enrollments e
  set claimed_until = now() + make_interval(secs => p_lease_seconds),
      updated_at = now()
  where e.id in (
    select id from followup_enrollments
    where status in ('active','waiting_reply')
      and next_eval_at <= now()
      and (claimed_until is null or claimed_until < now())
    order by next_eval_at
    limit p_limit
    for update skip locked
  )
  returning e.*;
$$;
revoke all on function fn_claim_due_followup_enrollments(int, int) from public, anon, authenticated;

-- ---- followup version lineage + atomic publish (migration 0056) ----

alter table followup_flow_versions
  add column if not exists pointer_id uuid references followup_flow_pointers(id) on delete cascade;

update followup_flow_versions v
set pointer_id = p.id
from followup_flow_pointers p
where p.active_version_id = v.id
  and v.pointer_id is null;

create index if not exists idx_followup_versions_pointer
  on followup_flow_versions (pointer_id);

create or replace function fn_publish_followup_flow_version(
  p_org uuid,
  p_pointer uuid,
  p_graph jsonb,
  p_created_by uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pointer record;
  v_version_id uuid;
begin
  select p.id, p.organization_id
    into v_pointer
  from followup_flow_pointers p
  where p.id = p_pointer
  for update;

  if not found or v_pointer.organization_id <> p_org then
    raise exception 'pointer_not_found' using errcode = 'P0001';
  end if;

  insert into followup_flow_versions (organization_id, pointer_id, graph, created_by)
  values (p_org, p_pointer, p_graph, p_created_by)
  returning id into v_version_id;

  update followup_flow_pointers
     set active_version_id = v_version_id,
         status = 'active',
         updated_at = now()
   where id = p_pointer;

  return v_version_id;
end;
$$;
revoke all on function fn_publish_followup_flow_version(uuid, uuid, jsonb, uuid) from public, anon, authenticated;

-- ---- agent_inbox_items: kind 'followup_dead' (migration 0057) ----

-- A constraint NÃO é reconstruída aqui: o vocabulário desta migration já está
-- contido no bloco único do fim deste apêndice. Reconstruí-la com a lista da
-- época quebrava o update.sh de quem já tem linha com kind mais novo (era o
-- caso deste bloco: 'snooze_expired' e os 4 seguintes ainda não existiam).

-- ---- agent editor: seletor de fluxo de follow-up (migration 0061) ----

alter table ai_agent_versions
  add column if not exists followup jsonb not null default '{"enabled": false, "flow_pointer_ids": []}'::jsonb;

create or replace function fn_ai_agent_version_content_immutable() returns trigger
language plpgsql as $fn$
begin
  if old.status <> 'draft' and (
       new.system_prompt          is distinct from old.system_prompt
    or new.provider               is distinct from old.provider
    or new.model                  is distinct from old.model
    or new.credential_id          is distinct from old.credential_id
    or new.tool_ids               is distinct from old.tool_ids
    or new.trigger_config         is distinct from old.trigger_config
    or new.channel_session_id     is distinct from old.channel_session_id
    or new.max_steps              is distinct from old.max_steps
    or new.token_budget           is distinct from old.token_budget
    or new.cost_budget_cents      is distinct from old.cost_budget_cents
    or new.history_message_window is distinct from old.history_message_window
    or new.history_token_window   is distinct from old.history_token_window
    or new.handoff_keywords       is distinct from old.handoff_keywords
    or new.handoff_tool_enabled   is distinct from old.handoff_tool_enabled
    or new.followup               is distinct from old.followup
    or new.version_number         is distinct from old.version_number
    or new.agent_id               is distinct from old.agent_id
    or new.organization_id        is distinct from old.organization_id
  ) then
    raise exception 'ai_agent_versions % é imutável (status=%): mudança de conteúdo = versão draft nova; rollback = revert (clona + publica)',
      old.id, old.status;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_ai_agent_versions_content_immutable on public.ai_agent_versions;
create trigger trg_ai_agent_versions_content_immutable
  before update on public.ai_agent_versions
  for each row execute function fn_ai_agent_version_content_immutable();

-- ---- followup enrollment: 1 vivo por lead ORG-WIDE + agent_id (migration 0064) ----
-- Dedup ANTES de trocar o índice (self-host-safe: o update.sh re-aplica sem
-- ON_ERROR_STOP, então o dado sujo tem que ser curado antes da constraint).
with ranked as (
  select id,
         row_number() over (
           partition by organization_id, contact_id
           order by started_at desc, id desc
         ) as rn
  from followup_enrollments
  where status in ('active', 'waiting_reply', 'paused_handoff')
)
update followup_enrollments e
set status = 'cancelled',
    cancel_reason = 'exclusivity_backfill',
    next_eval_at = null,
    updated_at = now()
from ranked
where e.id = ranked.id
  and ranked.rn > 1;

drop index if exists idx_followup_enrollments_one_live;
create unique index if not exists idx_followup_enrollments_one_live
  on followup_enrollments (organization_id, contact_id)
  where status in ('active', 'waiting_reply', 'paused_handoff');

alter table followup_enrollments
  add column if not exists agent_id uuid references ai_agents(id) on delete set null;
create index if not exists idx_followup_enrollments_agent
  on followup_enrollments (agent_id);
-- ---- bucket whatsapp-media (migration 0055) ----
insert into storage.buckets (id, name, public, file_size_limit)
values ('whatsapp-media', 'whatsapp-media', false, 52428800)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

-- ---- media multimodal: derivado + flags (migration 0058) ----
alter table messages
  add column if not exists media_derived_text text,
  add column if not exists media_derived_status text;
alter table ai_agent_versions
  add column if not exists multimodal_input boolean not null default true,
  add column if not exists video_frames_enabled boolean not null default false;

-- ---- split de mensagens por-agente (migration 0059) ----
alter table ai_agent_versions
  add column if not exists split_messages boolean not null default false,
  add column if not exists split_max_chars integer not null default 600;

-- ---- templates de script do vendedor (migration 0060) ----
create table if not exists message_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  owner_user_id uuid references auth.users(id) on delete cascade,
  title text not null,
  body text not null,
  shortcut text,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_message_templates_org on message_templates (organization_id);

alter table message_templates enable row level security;

drop policy if exists "message_templates_select" on message_templates;
create policy "message_templates_select" on message_templates
  for select using (
    (
      organization_id in (select fn_user_org_ids())
      and (owner_user_id is null or owner_user_id = auth.uid())
    )
    or fn_is_platform_admin()
  );

drop policy if exists "message_templates_write" on message_templates;
create policy "message_templates_write" on message_templates
  for all using (
    organization_id in (select fn_user_org_ids())
    and (
      (owner_user_id = auth.uid() and fn_role_at_least(organization_id, 'agent'))
      or (owner_user_id is null and fn_role_at_least(organization_id, 'manager'))
    )
  )
  with check (
    organization_id in (select fn_user_org_ids())
    and (
      (owner_user_id = auth.uid() and fn_role_at_least(organization_id, 'agent'))
      or (owner_user_id is null and fn_role_at_least(organization_id, 'manager'))
    )
  );

-- ---- snooze por conversa (migration 0062) ----
alter table conversations
  add column if not exists snooze_until timestamptz,
  add column if not exists snoozed_by_user_id uuid references auth.users(id) on delete set null,
  add column if not exists snoozed_at timestamptz;

create index if not exists idx_conversations_snooze_until
  on conversations (snooze_until) where snooze_until is not null;

-- (constraint agent_inbox_items_kind_check: definida uma vez só, no fim deste
--  apêndice — ver "vocabulário completo". 'snooze_expired' está lá.)

-- ---- notas internas de conversa (migration 0063) ----
create table if not exists conversation_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  body text not null,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_by_name text,
  created_at timestamptz not null default now()
);
create index if not exists idx_conversation_notes_conversation
  on conversation_notes (conversation_id, created_at);

alter table conversation_notes enable row level security;

drop policy if exists "conversation_notes_select" on conversation_notes;
create policy "conversation_notes_select" on conversation_notes
  for select using (
    organization_id in (select fn_user_org_ids()) or fn_is_platform_admin()
  );

drop policy if exists "conversation_notes_write" on conversation_notes;
create policy "conversation_notes_write" on conversation_notes
  for all using (
    organization_id in (select fn_user_org_ids()) and fn_role_at_least(organization_id, 'agent')
  )
  with check (
    organization_id in (select fn_user_org_ids()) and fn_role_at_least(organization_id, 'agent')
  );

-- ---- human cases (migration 0066) ----
create table if not exists agent_cases (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  lead_id uuid references crm_leads(id) on delete set null,
  agent_id uuid references ai_agents(id) on delete set null,
  status text not null default 'awaiting_human'
    check (status in ('awaiting_human','awaiting_lead','resolved','escalated','cancelled')),
  title text not null,
  summary text not null,
  blocker text not null,
  context_snapshot jsonb not null default '{}'::jsonb,
  source text not null default 'agent' check (source in ('agent','guardrail_autofallback')),
  followup_attempts smallint not null default 0,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists agent_cases_open_idx
  on agent_cases (organization_id, status) where status in ('awaiting_human','awaiting_lead');
create index if not exists agent_cases_lead_idx on agent_cases (organization_id, lead_id);
create index if not exists agent_cases_conv_idx on agent_cases (organization_id, conversation_id);

create table if not exists agent_case_events (
  id uuid primary key default uuid_generate_v4(),
  organization_id uuid not null references organizations(id) on delete cascade,
  case_id uuid not null references agent_cases(id) on delete cascade,
  kind text not null check (kind in
    ('opened','human_replied','lead_asked','lead_provided','lead_unresponsive','resolved','escalated','cancelled')),
  actor_kind text not null check (actor_kind in ('agent','human','system','lead')),
  actor_user_id uuid references auth.users(id) on delete set null,
  human_action text check (human_action in ('resolved','need_lead_info','escalate')),
  body text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists agent_case_events_case_idx on agent_case_events (case_id, created_at);

alter table ai_agent_versions add column if not exists cases_enabled boolean not null default false;

alter table agent_cases enable row level security;
alter table agent_case_events enable row level security;
-- A policy `for all` não nasce mais aqui desde a 0279: quem escreve caso é o
-- motor, e a leitura ganhou policy própria (`tenant_isolation_agent_cases_select`).
-- O par drop+create mora no bloco da 0279, colado, pelo motivo escrito acima.
drop policy if exists tenant_isolation_agent_case_events_select on agent_case_events;
create policy tenant_isolation_agent_case_events_select on agent_case_events
  for select using (organization_id in (select fn_user_org_ids()));
-- A policy de INSERT não nasce mais aqui desde a 0279 (mesmo motivo da tabela
-- mãe); quem a derruba no clone que já a tem é o bloco da 0279. A de SELECT,
-- logo acima, fica: a tela e o MCP leem.

-- estender CHECKs de job_queue (kind + coerência kind⇔contato) p/ case_reply_turn
-- nomes reais conferidos no banco linkado: job_queue_kind_check (named) e
-- job_queue_check (anônimo, gerado pelo Postgres) para o CHECK de coerência.
alter table job_queue drop constraint if exists job_queue_kind_check;
alter table job_queue add constraint job_queue_kind_check
  -- 'operator_turn' (migration 0111, spec 16 §3.2) entra NESTE bloco, não num
  -- novo no fim: reconstruir a mesma constraint em N blocos quebra o update.sh
  -- de todo clone que já tenha uma linha de vocabulário posterior — os blocos
  -- antigos rodam antes e falham em cadeia. Vigiado por
  -- tests/unit/baseline-constraint-reconstruida.test.ts.
  -- 'transactional_delivery' (0226) segue a mesma consolidação de vocabulário.
  check (kind in ('inbound_turn','followup_turn','watchdog','flywheel','case_reply_turn','operator_turn','transactional_delivery','approved_reply'));
alter table job_queue drop constraint if exists job_queue_turn_needs_contact;
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid = 'job_queue'::regclass and contype='c'
     and pg_get_constraintdef(oid) ilike '%contact_id is not null%';
  if c is not null then execute format('alter table job_queue drop constraint %I', c); end if;
end $$;
alter table job_queue add constraint job_queue_turn_needs_contact
  check ((kind in ('inbound_turn','followup_turn','case_reply_turn','operator_turn','transactional_delivery','approved_reply')) = (contact_id is not null));

alter table cron_jobs drop constraint if exists cron_jobs_job_kind_check;
alter table cron_jobs add constraint cron_jobs_job_kind_check
  check (job_kind in ('inbound_turn','followup_turn','watchdog','flywheel','case_reply_turn'));

-- ---- agent_inbox_items: reconcilia kind check followup_dead+snooze_expired (migration 0065) ----

-- (constraint agent_inbox_items_kind_check: definida uma vez só, no fim deste
--  apêndice — ver "vocabulário completo". Os dois valores desta migration
--  estão lá.)
-- ---- memória geral da org: org_memory_versions/pointers/entries (migration 0067) ----
-- 0067: Memória Geral da Org (Fase 1 do épico harness — spec 2026-07-23).
-- Doc-mãe versionado (padrão versões-imutáveis+ponteiro do playbook 0004/0050)
-- + entradas de aprendizado individuais (manual | flywheel com aprovação humana).

create table if not exists org_memory_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  version_number int not null,
  content text not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, version_number)
);

drop trigger if exists trg_org_memory_versions_immutable on org_memory_versions;
create trigger trg_org_memory_versions_immutable
  before update on org_memory_versions
  for each row execute function fn_agent_versions_immutable();

create table if not exists org_memory_pointers (
  organization_id uuid not null unique references organizations(id) on delete cascade,
  version_id uuid not null references org_memory_versions(id),
  updated_at timestamptz not null default now()
);

create table if not exists org_memory_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  title text not null check (length(title) > 0),
  body text not null check (length(body) > 0),
  source text not null check (source in ('manual', 'flywheel')),
  status text not null default 'active' check (status in ('proposed', 'active', 'archived')),
  proposal_id uuid references flywheel_distiller_proposals(id) on delete set null,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_org_memory_entries_org_status
  on org_memory_entries (organization_id, status, created_at);

-- Flywheel: novo destino de proposta (entry de memória da org).
alter table flywheel_distiller_proposals drop constraint if exists flywheel_distiller_proposals_type_check;
alter table flywheel_distiller_proposals add constraint flywheel_distiller_proposals_type_check
  check (type in ('playbook_bullet', 'golden_case', 'reentry_trigger', 'org_memory_entry'));

-- RLS (mesmo shape do loop tenant_isolation_* do baseline).
-- A rotina da migration 0325 no lugar do laço enumerado: ela varre o catálogo
-- procurando tabela de organização com RLS DESLIGADA, que neste ponto do arquivo
-- é exatamente o conjunto que a lista enumerava (medido, tabela a tabela).
do $$ begin perform public.fn_proteger_tabelas_de_organizacao(); end $$;

-- ---- skills instaláveis: manifest + skill_activations + catálogo (migration 0068) ----
-- 0068: Skills instaláveis + marketplace (Fase 2 do épico harness — spec 2026-07-23).
-- Manifest de arquivos na versão de skill + telemetria de ativação + bucket de
-- assets + leitura do catálogo de plataforma por clientes user-scoped.

alter table skill_versions add column if not exists manifest jsonb not null default '[]'::jsonb;
alter table skill_versions add column if not exists forked_from_version_id uuid references skill_versions(id) on delete set null;

create table if not exists skill_activations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  skill_name text not null,
  skill_version_id uuid references skill_versions(id) on delete set null,
  trigger text not null check (trigger in ('hard', 'probe')),
  job_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists idx_skill_activations_org_created
  on skill_activations (organization_id, created_at);
create index if not exists idx_skill_activations_skill
  on skill_activations (organization_id, skill_name, created_at);

-- RLS das tabelas org-scoped novas (skill_activations). skill_versions/pointers já
-- estão no loop tenant_isolation do baseline; a leitura de catálogo é policy extra abaixo.
-- A rotina da migration 0325 no lugar do laço enumerado: ela varre o catálogo
-- procurando tabela de organização com RLS DESLIGADA, que neste ponto do arquivo
-- é exatamente o conjunto que a lista enumerava (medido, tabela a tabela).
do $$ begin perform public.fn_proteger_tabelas_de_organizacao(); end $$;

-- Catálogo do marketplace: qualquer usuário autenticado LÊ as skills de plataforma
-- (organization_id null). Só SELECT; escrita de plataforma continua service-role.
drop policy if exists catalog_read_skill_versions on skill_versions;
create policy catalog_read_skill_versions on skill_versions for select
  to authenticated using (organization_id is null);
drop policy if exists catalog_read_skill_pointers on skill_pointers;
create policy catalog_read_skill_pointers on skill_pointers for select
  to authenticated using (organization_id is null);

-- ---- seed de skills de plataforma: catálogo inicial do marketplace (migration 0069) ----
-- 0069: seed de skills de plataforma (organization_id null) — catálogo inicial do
-- marketplace de skills (Fase 2 do épico harness). Duas skills de fábrica, qualidade
-- sobre quantidade: `objecao-preco` (vendas/genérico) e `agendamento` (clínicas/
-- serviços). Visíveis em toda org via a policy catalog_read_* acima.
--
-- Idempotente: cada bloco só insere versão+ponteiro se o ponteiro de plataforma
-- ainda não existir pra aquele nome — evita versão órfã (skill_versions é imutável,
-- sem UPDATE possível) e respeita o unique index uniq_skill_pointers_platform em
-- re-run.

do $seed$
declare
  v_id uuid;
begin
  if not exists (
    select 1 from skill_pointers where organization_id is null and name = 'objecao-preco'
  ) then
    insert into skill_versions (organization_id, name, description, body, matcher)
    values (
      null,
      'objecao-preco',
      'Playbook pra contornar objeção de preço no WhatsApp — diagnostica o motivo real por trás do "caro" antes de reagir, sem ceder desconto não autorizado.',
      $body$# Playbook: contornar objeção de preço

## Quando usar
O lead reagiu ao preço/valor com resistência — direta ("tá caro") ou indireta (pediu
desconto, comparou com concorrente, sumiu depois de saber o valor). Objetivo: entender
a objeção real por trás do "caro" antes de reagir, e nunca ceder desconto que a
organização não autorizou.

## Diagnóstico primeiro — "caro" quase nunca é sobre o número
Antes de responder, identifique QUAL objeção está por trás:

1. **Orçamento real insuficiente** — "não tenho esse valor agora", "tá fora do meu orçamento"
2. **Não enxergou o valor ainda** — "por que custa isso?", silêncio após o preço, comparação vaga
3. **Comparação com concorrente/opção mais barata** — "vi mais barato em [X]", "achei um mais em conta"
4. **Tática de negociação** — pede desconto de cara, sem ter perguntado nada sobre o produto antes
5. **Timing** — "vou pensar", "deixa eu ver com [sócio/cônjuge]" disfarçado de objeção de preço

Se não der pra diagnosticar pela mensagem, PERGUNTE antes de argumentar: "Só pra eu
te ajudar melhor — é o valor em si, ou você tava esperando algo diferente do que
ofereci?"

## If-then por diagnóstico

**SE orçamento real insuficiente:**
- Não insista no preço cheio. Ofereça: parcelamento, plano de entrada, versão
  reduzida — SÓ o que já estiver documentado como opção legítima na base de
  conhecimento do tenant.
- NUNCA invente parcelamento ou desconto que não está documentado — se não souber a
  política, faça handoff.
- Não deprecie o lead por não ter orçamento. Trate como informação, não como recusa.

**SE não enxergou valor ainda:**
- Não repita o preço. Reforce o resultado concreto que o cliente ganha (não a lista
  de features).
- Use um número ou prova social real se a base de conhecimento tiver ("cliente X
  reduziu Y em Z semanas").
- Pergunta de reengajamento: "Faz sentido pra você o que isso resolve, ou ficou
  alguma dúvida sobre o que está incluso?"

**SE comparação com concorrente:**
- Não ataque o concorrente. Pergunte o que ele viu de diferente ("o que tinha nessa
  outra opção?") — geralmente revela se é preço mesmo ou outro critério (prazo,
  suporte, garantia).
- Destaque o diferencial real do tenant (o que a base de conhecimento tiver de
  posicionamento), não genérico.

**SE tática de negociação (pediu desconto sem contexto):**
- Não ceda automaticamente. Pergunte o que faria sentido fechar hoje — muitas vezes
  revela o número real que o lead tem em mente.
- Desconto SÓ se a organização tiver uma política documentada na base de
  conhecimento (RAG) pra esse cenário. Sem isso, handoff — decisão de preço fora do
  script é gate humano.

**SE for timing disfarçado ("vou pensar"):**
- Não pressione. Pergunte objetivamente o que falta pra decidir ("o que te ajudaria
  a decidir com mais segurança agora?").
- Agende um follow-up explícito (data/hora), não deixe em aberto — lead que "vai
  pensar" sem follow-up marcado esfria.

## Regras duras
- Nunca prometa desconto, brinde ou condição especial que não esteja na base de
  conhecimento do tenant (RAG) ou explicitamente configurada no agente.
- Nunca minta sobre "promoção que acaba hoje" ou crie urgência falsa.
- Se o lead ficar hostil, ameaçar cancelar ou pedir falar com humano — handoff
  imediato, sem insistir mais uma vez.
- Se depois de 2 trocas de mensagem a objeção não resolver, ofereça handoff
  explicitamente: "Quer que eu chame alguém do time pra fechar os detalhes com
  você?"

## Exemplos de resposta (tom, não copiar literal)
- "Entendo — antes de eu te passar mais opção, me conta: é o valor em si ou esperava
  algo diferente do que te mostrei?"
- "Faz sentido. Sobre o valor, hoje temos [opção documentada]. Isso ajudaria a caber
  no seu momento?"
- "Show, deixa eu confirmar contigo: o que faria sentido fechar hoje pra você?"

## O que NÃO fazer
- Não despeje a lista de preços de novo sem contexto.
- Não ignore a objeção e mude de assunto.
- Não use frases de pressão tipo "só até hoje" sem essa condição existir de verdade.
$body$,
      '{"any_keywords": ["caro", "tá caro", "está caro", "muito caro", "desconto", "abaixar o preço", "mais barato", "achei mais barato", "fora do meu orçamento", "não cabe no orçamento", "valor alto", "preço alto"], "probe_keywords": ["quanto custa", "qual o valor", "quanto é", "parcelamento", "condições de pagamento", "forma de pagamento"]}'::jsonb
    )
    returning id into v_id;

    insert into skill_pointers (organization_id, name, version_id)
    values (null, 'objecao-preco', v_id);
  end if;
end
$seed$;

do $seed$
declare
  v_id uuid;
begin
  if not exists (
    select 1 from skill_pointers where organization_id is null and name = 'agendamento'
  ) then
    insert into skill_versions (organization_id, name, description, body, matcher)
    values (
      null,
      'agendamento',
      'Playbook pra marcar/remarcar horário (consulta, visita, sessão) — oferece opções concretas de agenda real, nunca inventa disponibilidade, confirma por escrito antes de fechar.',
      $body$# Playbook: marcar horário/agendamento

## Quando usar
O lead pede pra marcar um horário, consulta, visita, demonstração ou sessão —
qualquer compromisso com data/hora. Comum em clínicas, imobiliárias (visitas),
serviços e consultorias.

## Regra de ouro: nunca invente disponibilidade
Se o agente não tiver acesso confirmado à agenda real do tenant (integração/consulta
de disponibilidade), NÃO ofereça horário específico. Diga que vai confirmar e faça
handoff, ou pergunte a preferência do lead e sinalize que a confirmação virá em
seguida. Prometer um horário que depois não existe quebra confiança e gera
reagendamento forçado.

## Fluxo padrão (if-then)

**1. Identifique o serviço/motivo antes de oferecer horário**
- SE o lead só disse "quero agendar" sem contexto → pergunte o motivo/serviço
  primeiro. Agendar sem saber o quê gera erro de encaixe (ex.: consulta de 20min
  marcada num slot de 1h de procedimento).

**2. Ofereça opções fechadas, não uma pergunta aberta**
- SE tiver acesso à agenda real → ofereça 2-3 horários concretos ("tenho terça 14h
  ou quarta 10h, qual funciona?"). Pergunta aberta tipo "qual horário você prefere?"
  gera ida e volta desnecessária e trava a conversa.
- SE não tiver acesso à agenda → não invente. Diga algo como "vou confirmar a
  disponibilidade e te retorno em instantes" e sinalize handoff/task pra quem tem
  acesso.

**3. Colete os dados obrigatórios antes de confirmar**
- Nome completo do lead (ou confirme o que já está no CRM).
- Serviço/motivo específico.
- Unidade/local, se o tenant tiver mais de uma (clínica com filiais, imobiliária com
  múltiplos imóveis).
- Se for reagendamento, o horário anterior a ser substituído.

**4. Confirme por escrito antes de encerrar**
- SE o lead aceitar um horário → repita de volta por escrito: "Confirmado:
  [serviço] dia [data] às [hora], em [local]. Confirma pra mim?"
- Só considere o agendamento fechado depois do "sim"/confirmação explícita do lead —
  silêncio ou "ok" vago não é confirmação suficiente pra compromissos com custo de
  no-show alto (ex. consulta médica, visita a imóvel).

**5. Reagendamento e cancelamento**
- SE o lead pedir pra remarcar → trate como novo agendamento: pergunte novo horário
  disponível, e cancele/substitua o anterior explicitamente (não deixe os dois
  marcados).
- SE o lead pedir pra cancelar → confirme o cancelamento e pergunte se quer remarcar
  pra outra data, sem pressionar.

**6. Risco de no-show**
- Se o negócio tiver política de confirmação D-1 documentada na base de
  conhecimento, siga-a (ex.: mensagem de lembrete automática). Se não houver, não
  invente política — apenas confirme o agendamento normalmente.

## Regras duras
- Nunca confirme horário sem ter checado disponibilidade real (ou sem sinalizar que
  ainda vai confirmar).
- Nunca marque dois compromissos conflitantes pro mesmo lead sem avisar.
- Se o lead pedir um horário fora do funcionamento do negócio (ex. domingo,
  madrugada) e isso não estiver nas regras do tenant, não confirme — explique a
  janela real de atendimento.
- Dado sensível (endereço completo, documento) só é coletado se o fluxo do tenant
  realmente exigir — não peça informação a mais que o agendamento precisa.

## Exemplos de resposta (tom, não copiar literal)
- "Pra eu te encaixar certo: é pra qual serviço/motivo?"
- "Tenho quinta às 15h ou sexta às 9h — qual fica melhor pra você?"
- "Confirmado: consulta dia 28/07 às 15h, na unidade Centro. Pode confirmar pra
  mim?"

## O que NÃO fazer
- Não pergunte "qual horário você prefere?" sem oferecer opções concretas quando
  você tem a agenda.
- Não confirme agendamento sem resposta explícita do lead.
- Não invente disponibilidade que você não checou.
$body$,
      '{"any_keywords": ["agendar", "marcar horário", "marcar consulta", "marcar uma visita", "agenda", "que horas vocês", "horário disponível", "remarcar", "reagendar", "cancelar o horário", "desmarcar"], "probe_keywords": ["que horas", "qual dia", "tem vaga", "disponibilidade"]}'::jsonb
    )
    returning id into v_id;

    insert into skill_pointers (organization_id, name, version_id)
    values (null, 'agendamento', v_id);
  end if;
end
$seed$;


-- ---- ai_pricing backfill (migration 0113, renumerada de 0068) ----
-- O NNNN original colidia com `0068_skills_marketplace`. O arquivo foi renomeado
-- (o timestamp `20260725150000` NAO mudou, entao a version do Supabase e a mesma e
-- ninguem re-aplica). As strings `notes` abaixo continuam dizendo "backfill 0068"
-- DE PROPOSITO: sao dado ja gravado nos bancos existentes, e reescrever dado para
-- acompanhar renumeracao de arquivo criaria divergencia entre clone antigo e novo
-- sem ganho nenhum. O guard `not exists` casa por `model`, nunca por `notes`.
-- BUG: ai_pricing nascia VAZIA em toda instalação nova. Os seeds existem só na
-- migration 0010, mas a cadeia fresh não sobe (as 10 primeiras são stubs
-- `SELECT 1;`) e quem instala aplica este baseline, que semeia ai_models mas
-- não ai_pricing. Com a tabela vazia, computeCost() devolve 0 sem log e o teto
-- de ai_budgets nunca dispara. Derivado de ai_models: idempotente e
-- auto-curativo, cobre qualquer modelo futuro do catálogo.
insert into public.ai_pricing (model, prompt_cents_per_million_tokens, completion_cents_per_million_tokens, notes)
select
  m.model_id,
  m.input_price_per_million_cents,
  m.output_price_per_million_cents,
  'backfill 0068 a partir de ai_models'
from public.ai_models m
where m.deprecated_at is null
  and m.input_price_per_million_cents is not null
  and m.output_price_per_million_cents is not null
  and not exists (
    select 1 from public.ai_pricing p
    where p.model = m.model_id and p.superseded_at is null
  );

-- Embedding do RAG — não vive em ai_models.
insert into public.ai_pricing (model, embedding_cents_per_million_tokens, notes)
select 'openai/text-embedding-3-small', 20, 'backfill 0068 (seed original da 0010)'
where not exists (
  select 1 from public.ai_pricing p
  where p.model = 'openai/text-embedding-3-small' and p.superseded_at is null
);
-- ---- crm_leads owner_kind/owner_agent_id (migration 0070) ----
-- CRM Vivo · Wave 1 (CORE 1): a IA é dona do NEGÓCIO, não só da conversa.
-- Mesmo padrão da 0032 (conversations.assignee_kind): backfill ANTES da
-- constraint, CHECK de coerência em forma de implicação, drop+add re-aplicável.
-- owner_agent_id aponta para ai_agents (identidade), NUNCA ai_agent_versions —
-- o tooltip "Nome · vN" resolve a versão publicada por join na hora de exibir.
alter table public.crm_leads
  add column if not exists owner_kind text
  check (owner_kind in ('user','ai'));

alter table public.crm_leads
  add column if not exists owner_agent_id uuid
  references public.ai_agents(id) on delete set null;

update public.crm_leads
   set owner_kind = 'user'
 where owner_user_id is not null
   and owner_kind is distinct from 'user';

update public.crm_leads
   set owner_kind = null
 where owner_user_id is null
   and owner_agent_id is null
   and owner_kind = 'user';

update public.crm_leads
   set owner_kind = 'ai'
 where owner_agent_id is not null
   and owner_kind is distinct from 'ai';

alter table public.crm_leads
  drop constraint if exists crm_leads_owner_kind_coherence;
alter table public.crm_leads
  add constraint crm_leads_owner_kind_coherence check (
    (owner_kind = 'user' and owner_user_id is not null and owner_agent_id is null) or
    (owner_kind = 'ai'   and owner_agent_id is not null and owner_user_id is null) or
    (owner_kind is null)
  );

create index if not exists idx_crm_leads_owner_agent
  on public.crm_leads (organization_id, owner_agent_id)
  where owner_agent_id is not null;

-- lead.assigned passa a cobrir o dono agente (corpo da 0043 + ramo do agente).
create or replace function public.fn_emit_event_on_lead_change() returns trigger
    language plpgsql
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'INSERT' then
    return new;
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

  if new.owner_user_id is distinct from old.owner_user_id
     or new.owner_agent_id is distinct from old.owner_agent_id then
    perform public.fn_log_event(new.organization_id, 'lead.assigned',
      jsonb_build_object(
        'lead_id', new.id,
        'from_user_id', old.owner_user_id, 'to_user_id', new.owner_user_id,
        'from_agent_id', old.owner_agent_id, 'to_agent_id', new.owner_agent_id,
        'owner_kind', new.owner_kind));
  end if;

  return new;
end$$;


-- ---- crm_lead_activities: barramento único da vida do lead (migration 0071) ----
-- Wave 3, bloco 1 do CRM Vivo. actor_kind/actor_agent_id/reason/evidence +
-- stage_changed_at em crm_leads. Realtime desta tabela entra pelo array do loop
-- de publicação, acima.
--
-- FRONTEIRA DIRC: source_module/source_id = O QUE ORIGINOU (um ponteiro);
-- evidence = O QUE SUSTENTA (N referências). evidence nunca repete o source_id.
--
-- Idempotente e AUTO-CURATIVO: o backfill lê actor_kind/reason de metadata (onde
-- o orquestrador de handoff já os grava hoje) ANTES de a constraint existir, e
-- degrada para 'system' a linha marcada como 'ai' sem lastro nenhum — senão o
-- update.sh de um clone quebraria ao criar a constraint.

-- ---------------------------------------------------------------------------
-- A. Colunas do barramento
-- ---------------------------------------------------------------------------

-- 'contact' é a PESSOA do outro lado — não 'lead': deste lado da casa lead é o
-- NEGÓCIO (crm_leads), então 'lead' diria "o negócio falou". Também não
-- adotamos 'agent'/'human' de agent_case_events: aqui 'agent' já é papel humano
-- de RBAC (viewer < agent < manager < admin) e colidiria.
alter table public.crm_lead_activities
  add column if not exists actor_kind text
  check (actor_kind in ('user','ai','system','rule','contact'));

alter table public.crm_lead_activities
  add column if not exists actor_agent_id uuid
  references public.ai_agents(id) on delete set null;

-- O PORQUÊ em texto legível por humano — é o que a timeline mostra embaixo da
-- linha, e o que torna a decisão da IA discutível em vez de mágica.
alter table public.crm_lead_activities
  add column if not exists reason text;

-- O LASTRO: {"run_ids": [...], "trace_ids": [...]} — mesmo formato de
-- flywheel_distiller_proposals.evidence.
alter table public.crm_lead_activities
  add column if not exists evidence jsonb;

comment on column public.crm_lead_activities.actor_kind is
  'Quem agiu: user (humano do time) | ai (agente) | system (o produto) | rule (automação) | contact (a pessoa atendida). NUNCA "lead": lead aqui é o negócio.';
comment on column public.crm_lead_activities.evidence is
  'O que SUSTENTA a atividade: {"run_ids":[],"trace_ids":[]} (N referências). Não confundir com source_module/source_id, que é O QUE ORIGINOU (um ponteiro). evidence nunca repete o source_id — origem não é prova.';
comment on column public.crm_lead_activities.reason is
  'Por que esta atividade existe, em texto legível. Sem PII: é exibido na timeline e exportado no LGPD.';

-- ---------------------------------------------------------------------------
-- B. Backfill A PARTIR DO JSONB — antes de qualquer default e antes da
--    constraint (doutrina de migrations §8).
--
--    actor_kind e reason JÁ são gravados hoje dentro de metadata
--    (lib/ai/handoff/orchestrator.ts). Backfillar tudo como 'system' apagaria
--    informação que já existe — seria perda de dado disfarçada de migration.
-- ---------------------------------------------------------------------------

-- ORDEM IMPORTA: o lastro sobe ANTES do ator. Promover para 'ai' e degradar
-- depois funciona na primeira aplicação (a constraint ainda não existe) e
-- QUEBRA no update.sh de um clone, onde ela já existe e recusa a linha no ato.
-- Aqui nenhum estado intermediário inválido chega a existir.

-- 1. Lastro que já existe em metadata sobe para a coluna (nunca inventado).
update public.crm_lead_activities
   set evidence = jsonb_strip_nulls(
         jsonb_build_object(
           'run_ids',   metadata->'run_ids',
           'trace_ids', metadata->'trace_ids'
         ))
 where evidence is null
   and (jsonb_typeof(metadata->'run_ids') = 'array'
     or jsonb_typeof(metadata->'trace_ids') = 'array');

-- 2. Atores que não são a IA: promoção direta.
update public.crm_lead_activities
   set actor_kind = metadata->>'actor_kind'
 where actor_kind is null
   and metadata->>'actor_kind' in ('user','system','rule','contact');

-- 3. 'ai' só quando há execução que sustente a afirmação.
update public.crm_lead_activities
   set actor_kind = 'ai'
 where actor_kind is null
   and metadata->>'actor_kind' = 'ai'
   and (coalesce(jsonb_array_length(evidence->'run_ids'), 0) > 0
     or coalesce(jsonb_array_length(evidence->'trace_ids'), 0) > 0);

-- 4. 'ai' sem lastro nenhum vira 'system': o registro continua inteiro (o
--    reason é preservado); o que se recusa a afirmar é a AUTORIA da IA, porque
--    não há execução que a sustente.
update public.crm_lead_activities
   set actor_kind = 'system'
 where actor_kind is null
   and metadata->>'actor_kind' = 'ai';

update public.crm_lead_activities
   set reason = metadata->>'reason'
 where reason is null
   and nullif(metadata->>'reason', '') is not null;

-- 5. Quem tem autor humano registrado é 'user' — o dado está na coluna, só não
--    estava nomeado.
update public.crm_lead_activities
   set actor_kind = 'user'
 where actor_kind is null
   and performed_by_user_id is not null;

-- 6. Cura de banco onde a constraint ainda não existia e uma linha 'ai' entrou
--    sem lastro (não alcançável depois que a constraint existe — por isso vem
--    por último e é no-op no caminho feliz).
update public.crm_lead_activities
   set actor_kind = 'system'
 where actor_kind = 'ai'
   and coalesce(jsonb_array_length(evidence->'run_ids'), 0) = 0
   and coalesce(jsonb_array_length(evidence->'trace_ids'), 0) = 0;

-- ---------------------------------------------------------------------------
-- C. Constraint de lastro (drop+add — re-aplicável)
--
--    A doutrina do CORE 3 ("número sem porquê não é gravado") aplicada uma wave
--    antes: se a IA afirma algo na timeline, existe run_id ou trace_id que
--    sustente. `jsonb_array_length(...) > 0`, NÃO `evidence ? 'run_ids'` — a
--    segunda passa com array VAZIO, e lastro vazio não sustenta nada.
-- ---------------------------------------------------------------------------

alter table public.crm_lead_activities
  drop constraint if exists crm_lead_activities_ai_needs_evidence;
-- A constraint NÃO é recriada aqui, e sim uma vez só mais abaixo, na versão que
-- também aceita `llm_call_ids`. Recriá-la com a lista da época derrubava o
-- update.sh de quem já tem atividade de IA cuja evidência é só `llm_call_ids`.

-- Timeline por ator (o dossiê filtra "só o que a IA fez"), parcial porque a
-- maioria das linhas não é de agente.
create index if not exists idx_lead_activities_org_actor_agent
  on public.crm_lead_activities (organization_id, actor_agent_id, performed_at desc)
  where actor_agent_id is not null;

-- ---------------------------------------------------------------------------
-- D. stage_changed_at — de carona, porque esta wave passa a emitir atividade na
--    mudança de estágio. Sem a coluna, "3d em Negociação" no card continua
--    medindo tempo SEM RESPOSTA (last_activity_at) e mente sobre o estágio.
--    Trigger puro: carimba a coluna, sem HTTP (doutrina — trigger nunca faz rede).
-- ---------------------------------------------------------------------------

alter table public.crm_leads
  add column if not exists stage_changed_at timestamptz;

-- Bancos existentes: o melhor palito honesto é a criação do lead — nunca
-- inventar uma data de entrada no estágio que ninguém registrou.
update public.crm_leads
   set stage_changed_at = created_at
 where stage_changed_at is null;

alter table public.crm_leads
  alter column stage_changed_at set default now();

create or replace function public.fn_stamp_stage_changed_at() returns trigger
    language plpgsql
    set search_path to 'public', 'pg_temp'
    as $$
begin
  if tg_op = 'INSERT' then
    new.stage_changed_at := coalesce(new.stage_changed_at, now());
  elsif new.stage_id is distinct from old.stage_id then
    new.stage_changed_at := now();
  end if;
  return new;
end$$;

drop trigger if exists trg_stamp_stage_changed_at on public.crm_leads;
create trigger trg_stamp_stage_changed_at
  before insert or update on public.crm_leads
  for each row execute function public.fn_stamp_stage_changed_at();

comment on column public.crm_leads.stage_changed_at is
  'Quando o lead entrou no estágio atual. Carimbado por trigger. É o relógio de "tempo no estágio" do card — distinto de last_activity_at, que é "tempo sem resposta".';

-- ---- evidence: lastro pode apontar para llm_calls (migration 0072) ----
-- Só AFROUXA a constraint (acrescenta uma terceira forma de lastro), então
-- nenhuma linha existente passa a violá-la e o update.sh de clone não quebra.
-- Idempotente por drop+add.
alter table public.crm_lead_activities
  drop constraint if exists crm_lead_activities_ai_needs_evidence;

alter table public.crm_lead_activities
  add constraint crm_lead_activities_ai_needs_evidence check (
    actor_kind <> 'ai'
    or coalesce(jsonb_array_length(evidence->'run_ids'), 0) > 0
    or coalesce(jsonb_array_length(evidence->'trace_ids'), 0) > 0
    or coalesce(jsonb_array_length(evidence->'llm_call_ids'), 0) > 0
  );

comment on column public.crm_lead_activities.evidence is
  'O que SUSTENTA a atividade (N referências), cada chave apontando para UMA tabela: run_ids→ai_agent_runs, trace_ids→o trace do turno, llm_call_ids→llm_calls. Não confundir com source_module/source_id, que é O QUE ORIGINOU (um ponteiro). evidence nunca repete o source_id — origem não é prova.';

-- ---- identidade da próxima ação + caixa para o caso ambíguo (migration 0073) ----
-- Duas mudanças independentes, ambas idempotentes e auto-curativas.
--
-- `next_action_seq` distingue "a mesma proposta" de "a mesma frase": o agente
-- pode reescrever o mesmo texto significando outra coisa, e a autorização
-- humana precisa saber QUAL proposta foi lida. Default 0 para as linhas que já
-- existem — o primeiro reescrever leva a 1, que é o correto: a proposta que
-- estava lá antes desta coluna nunca foi autorizada por ninguém.
alter table public.lead_state
  add column if not exists next_action_seq bigint not null default 0;

comment on column public.lead_state.next_action_seq is
  'Identidade da proposta corrente. Incrementa a CADA escrita de next_action, inclusive quando o texto novo é idêntico ao anterior — é o que distingue "a mesma proposta" de "a mesma frase". A autorização humana carrega este número; a execução o compara. Nunca usar updated_at no lugar: ele se move por outras escritas do estado.';

-- Só ACRESCENTA um kind, então nenhuma linha existente passa a violar a
-- constraint e o update.sh de um clone não quebra. Idempotente por drop+add.
-- `followup_dead` está aqui porque a lista é a do BASELINE, não a do banco de
-- dev: os dois divergiram, e o dev está com uma versão ANTERIOR da constraint
-- (sem esse valor) enquanto lib/followup/engine.ts insere exatamente esse kind.
-- Reconstruir a partir do banco apagaria o valor e mataria, em silêncio, o
-- aviso de enrollment morto. A fonte de verdade é o arquivo versionado.
-- (constraint agent_inbox_items_kind_check: definida uma vez só, no fim deste
--  apêndice — ver "vocabulário completo". 'next_action_ambiguous' está lá.)

-- ---- score de probabilidade com evidência, em tabela própria (migrations 0074+0075) ----
-- O baseline salta o passo intermediário de propósito: quem instala do zero não
-- deve ganhar as colunas em `crm_leads` para perdê-las na linha seguinte. Para
-- quem ATUALIZA (update.sh) o bloco continua correto — o `drop column if exists`
-- e a migração de dados abaixo cuidam de um clone que já aplicou a 0074.
create table if not exists public.crm_lead_scores (
  lead_id uuid primary key references public.crm_leads(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  ai_probability numeric(5, 2),
  ai_probability_reason text,
  ai_probability_evidence jsonb not null default '{}'::jsonb,
  ai_probability_at timestamptz,
  ai_probability_band text,
  ai_probability_band_since timestamptz,
  updated_at timestamptz not null default now()
);

-- `primary key (lead_id)` já garante o 1:1 — um lead tem no máximo uma linha de
-- score. FK com `on delete cascade`: score é sobre o negócio, e sem o negócio
-- não significa nada (não é histórico, é estado corrente).

comment on table public.crm_lead_scores is
  'Score de probabilidade por lead, FORA de crm_leads de propósito. Ver o cabeçalho da migration 0075: trazer estes campos de volta reintroduz o pulso que mente (board assina crm_leads) e o 409 fantasma (trava otimista do move + trigger de updated_at). Fica FORA da publicação supabase_realtime — recálculo é telemetria e não deve pintar card; quem pinta é a atividade emitida na travessia de faixa.';

-- ---- migra o que existir (clones que já aplicaram a 0074) ----
-- SQL DINÂMICO de propósito: numa instalação NOVA as colunas nunca existiram em
-- `crm_leads`, e o Postgres faz o parse do comando ANTES de avaliar qualquer
-- guarda — `where exists (select from information_schema...)` não salva, porque
-- o erro é de parse, não de execução. Só `execute` adia a resolução do nome.
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'crm_leads'
       and column_name = 'ai_probability'
  ) then
    execute $mig$
      insert into public.crm_lead_scores (
        lead_id, organization_id, ai_probability, ai_probability_reason,
        ai_probability_evidence, ai_probability_at, ai_probability_band,
        ai_probability_band_since
      )
      select l.id, l.organization_id, l.ai_probability, l.ai_probability_reason,
             coalesce(l.ai_probability_evidence, '{}'::jsonb), l.ai_probability_at,
             l.ai_probability_band, l.ai_probability_band_since
        from public.crm_leads l
       where l.ai_probability is not null
      on conflict (lead_id) do nothing
    $mig$;
  end if;
end $$;

alter table public.crm_leads
  drop constraint if exists crm_leads_score_needs_reason,
  drop constraint if exists crm_leads_score_range,
  drop constraint if exists crm_leads_score_band_check,
  drop constraint if exists crm_leads_score_band_coherence;

alter table public.crm_leads
  drop column if exists ai_probability,
  drop column if exists ai_probability_reason,
  drop column if exists ai_probability_evidence,
  drop column if exists ai_probability_at,
  drop column if exists ai_probability_band,
  drop column if exists ai_probability_band_since;

-- ---- as mesmas garantias, agora na tabela certa ----
alter table public.crm_lead_scores
  drop constraint if exists crm_lead_scores_needs_reason;

-- ---- evidência do score: FONTE ÚNICA (migrations 0076+0077) ----
-- ---- limpeza ANTES da constraint ----
-- Hoje são 0 linhas de 2, mas o CHECK nunca exigiu âncora DENTRO do fator: um
-- clone pode ter `factors` sem âncora nenhuma, e essa linha passa hoje e
-- reprovaria depois. Apaga o SCORE — não inventa âncora, porque âncora
-- fabricada aponta para um registro que não sustenta nada e é indistinguível
-- da verdadeira.
update public.crm_lead_scores
   set ai_probability = null,
       ai_probability_reason = null,
       ai_probability_at = null,
       ai_probability_band = null,
       ai_probability_band_since = null,
       updated_at = now()
 where ai_probability is not null
   and (
     coalesce(jsonb_array_length(ai_probability_evidence -> 'factors'), 0) = 0
     or not (ai_probability_evidence @? '$.factors[*].ancora')
   );

alter table public.crm_lead_scores
  drop constraint if exists crm_lead_scores_needs_reason;

alter table public.crm_lead_scores
  add constraint crm_lead_scores_needs_reason check (
    ai_probability is null
    or (
      ai_probability_reason is not null
      and btrim(ai_probability_reason) <> ''
      -- LEGÍVEL: o que o hover revela.
      and coalesce(jsonb_array_length(ai_probability_evidence -> 'factors'), 0) > 0
      -- RASTREÁVEL: para onde o clique leva. `@?` com jsonpath em vez de
      -- subconsulta, que CHECK não aceita — e é o que permite exigir a âncora
      -- DENTRO do fator, mantendo a fonte única.
      and ai_probability_evidence @? '$.factors[*].ancora'
    )
  );

comment on column public.crm_lead_scores.ai_probability_evidence is
  'O QUE SUSTENTA o score, em FONTE ÚNICA: `factors` — cada parcela com `pontos` (com sinal), `frase` legível e, quando há ponto no tempo, `ancora` {kind,id}. A constraint exige factors não-vazio E pelo menos um fator com âncora: legível sem rastreável é adjetivo, rastreável sem legível é um id que ninguém entende. NÃO unificar com o formato de crm_lead_activities.evidence (arrays de ids por tabela): a diferença é deliberada e está explicada na migration 0077 — atividade cita FATOS de N tabelas, score cita PARCELAS de um cálculo. Unificar reintroduz as duas listas que já divergiram uma vez (0076), com o banco cobrando uma chave e a tela lendo outra.';

alter table public.crm_lead_scores
  drop constraint if exists crm_lead_scores_range;

alter table public.crm_lead_scores
  add constraint crm_lead_scores_range check (
    ai_probability is null or (ai_probability >= 0 and ai_probability <= 100)
  );

alter table public.crm_lead_scores
  drop constraint if exists crm_lead_scores_band_check;

alter table public.crm_lead_scores
  add constraint crm_lead_scores_band_check check (
    ai_probability_band is null
    or ai_probability_band = any (array['frio', 'morno', 'quente']::text[])
  );

alter table public.crm_lead_scores
  drop constraint if exists crm_lead_scores_band_coherence;

alter table public.crm_lead_scores
  add constraint crm_lead_scores_band_coherence check (
    ai_probability_band is null
    or ai_probability is null
    or (ai_probability_band = 'quente' and ai_probability >= 65)
    or (ai_probability_band = 'morno' and ai_probability >= 35 and ai_probability <= 75)
    or (ai_probability_band = 'frio' and ai_probability <= 45)
  );

comment on column public.crm_lead_scores.ai_probability is
  'Probabilidade 0-100 por FÓRMULA determinística sobre sinais que já existem — nunca chamada de modelo. Com fórmula, o reason é DERIVADO do cálculo e "número sem porquê" é impossível por construção; com modelo, a frase é gerada ao lado do número e a lei só pareceria cumprida. null = sinal insuficiente, e é estado legítimo: nunca zero.';

comment on column public.crm_lead_scores.ai_probability_reason is
  'O PORQUÊ em português, obrigatório por constraint quando há score. Existe para o humano poder DISCORDAR: sem razão citável o número é opinião sem apelação.';

comment on column public.crm_lead_scores.ai_probability_evidence is
  'O QUE SUSTENTA (N referências): activity_ids→crm_lead_activities, message_ids→messages, checkpoint_ids→lead_checkpoints. A constraint exige pelo menos uma — razão sem referência é adjetivo.';

comment on column public.crm_lead_scores.ai_probability_band is
  'Faixa exibida. Persistida porque histerese precisa da faixa anterior; o CHECK de coerência torna divergir do score IMPOSSÍVEL de gravar, não só improvável. Cortes em FAIXA_LIMITES (lib/kanban/score-band.ts), fonte única do CHECK, do emissor e da UI.';

-- ---- tenancy ----
alter table public.crm_lead_scores enable row level security;

drop policy if exists tenant_isolation_crm_lead_scores_all on public.crm_lead_scores;
create policy tenant_isolation_crm_lead_scores_all on public.crm_lead_scores
  for all
  using (organization_id in (select fn_user_org_ids()))
  with check (organization_id in (select fn_user_org_ids()));

create index if not exists idx_crm_lead_scores_org_band
  on public.crm_lead_scores (organization_id, ai_probability_band);

-- FORA da publicação de realtime — é o ponto inteiro desta migration. Remover
-- é defensivo: se um clone tiver a tabela publicada por engano, isto corrige.
do $$
begin
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'crm_lead_scores'
  ) then
    execute 'alter publication supabase_realtime drop table public.crm_lead_scores';
  end if;
end $$;

-- ---- estado de risco do negócio (migration 0078) ----
-- 0078 — "esfriando" deixa de ser adjetivo calculado e vira ESTADO do negócio
--
-- O QUE ESTAVA ERRADO: `classifyRisk` é função pura recalculada a cada leitura,
-- e os únicos chamadores são rotas de LEITURA. Nenhum worker, nenhum emissor.
-- Consequência medida: "esfriando" não existia até alguém abrir a tela, não
-- tinha tipo de atividade (o vocabulário não sabia dizer "esfriou" nem
-- "voltou"), e — o pior — não era RETIDO: não havia como responder "há quanto
-- tempo está esfriando" nem "quantas vezes já esfriou e voltou".
--
-- A ironia que motivou a wave: o cabeçalho de `lib/leads/risk-radar.ts` declara
-- ser o desilhamento C1 da doutrina do sistema vivo — "uma demanda que esfriou
-- e não tem próximo passo garantido está morrendo sem ninguém ver; o radar a
-- torna visível". Mas tornar visível numa tela que ninguém é obrigado a abrir
-- não é mecanismo anti-morte: é a mesma morte, com testemunha opcional.
--
-- ⚠️ POR QUE FORA DE `crm_leads` — os dois motivos são os MESMOS da 0075 e
-- valem palavra por palavra aqui; leia aquele cabeçalho antes de "simplificar"
-- isto para dentro do lead:
--   1. o PULSO QUE MENTE — o board assina `crm_leads`; uma varredura de risco
--      em lote faria dezenas de cards piscarem sem novidade nenhuma;
--   2. o 409 FANTASMA — `trg_crm_leads_updated_at` invalida a trava otimista do
--      arrasto em voo, e o usuário recebe "alguém editou este lead" quando
--      ninguém editou.
--
-- ⚠️ MAS ESTA TABELA FICA **DENTRO** DA PUBLICAÇÃO DE REALTIME, ao contrário da
-- `crm_lead_scores`. Isso NÃO contradiz a 0075 — é a mesma regra aplicada:
-- "silêncio para telemetria, pulso para mudança de estado". Score é telemetria
-- (número que se move sozinho o tempo todo); risco é transição discreta e rara
-- que EXIGE ação humana. É por aqui que a borda de aviso aparece sem reload,
-- sem tocar o lead — e é justamente não tocar o lead que preserva 1 e 2.
--
-- A CONTRAPARTIDA, que vive no escritor e não dá para o banco garantir: só
-- escreva quando o BUCKET MUDAR. Um `update` que só refresca `detected_at`
-- publicaria evento de realtime sem mudança de estado, e o board voltaria a
-- piscar à toa — o defeito que esta separação toda existe para impedir.

create table if not exists public.crm_lead_risk_states (
  lead_id uuid primary key references public.crm_leads(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  bucket text not null,
  -- QUANDO O NEGÓCIO ENTROU NESTE ESTADO, que não é quando o sistema percebeu.
  -- A distinção é o que torna o acervo honesto: os 48 negócios já frios no dia
  -- da estreia entram com `since` no passado (o instante em que de fato
  -- esfriaram) e `detected_at` em now. Sem os dois campos, o histórico diria
  -- que todos esfriaram no mesmo minuto — e diria isso para sempre.
  since timestamptz not null,
  detected_at timestamptz not null default now(),
  -- A janela do estágio usada na decisão, gravada JUNTO. Sem ela, mudar
  -- `expected_duration_hours` reescreve retroativamente o significado de todo
  -- estado já gravado, e ninguém consegue explicar por que aquele negócio
  -- esfriou "às 24h" se hoje o estágio diz 72h.
  cold_hours numeric not null,
  updated_at timestamptz not null default now()
);

comment on table public.crm_lead_risk_states is
  'Estado de risco por negócio (wave 7 — o ciclo). FORA de crm_leads pelos motivos da 0075 (pulso que mente, 409 fantasma), mas DENTRO da publicação supabase_realtime, ao contrário de crm_lead_scores: risco é mudança de estado, não telemetria. O escritor só grava quando o bucket muda.';

alter table public.crm_lead_risk_states
  drop constraint if exists crm_lead_risk_states_bucket_check;
alter table public.crm_lead_risk_states
  add constraint crm_lead_risk_states_bucket_check check (
    bucket = any (array['em_dia', 'em_voo', 'em_risco', 'critico']::text[])
  );

-- Estado não começa no futuro. Trava o erro de gravar `since = now + janela`
-- (o instante em que VAI esfriar) em vez de `last_activity_at + janela`.
alter table public.crm_lead_risk_states
  drop constraint if exists crm_lead_risk_states_since_no_passado;
alter table public.crm_lead_risk_states
  add constraint crm_lead_risk_states_since_no_passado check (since <= detected_at);

alter table public.crm_lead_risk_states
  drop constraint if exists crm_lead_risk_states_cold_hours_positivo;
alter table public.crm_lead_risk_states
  add constraint crm_lead_risk_states_cold_hours_positivo check (cold_hours > 0);

alter table public.crm_lead_risk_states enable row level security;

drop policy if exists tenant_isolation_crm_lead_risk_states_all on public.crm_lead_risk_states;
create policy tenant_isolation_crm_lead_risk_states_all on public.crm_lead_risk_states
  for all
  using (organization_id in (select fn_user_org_ids()))
  with check (organization_id in (select fn_user_org_ids()));

-- O radar lê "quem está em risco nesta org", nesta ordem.
create index if not exists idx_crm_lead_risk_states_org_bucket
  on public.crm_lead_risk_states (organization_id, bucket, since);

-- DENTRO da publicação — ver o cabeçalho. Idempotente: só adiciona se faltar.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'crm_lead_risk_states'
  ) then
    execute 'alter publication supabase_realtime add table public.crm_lead_risk_states';
  end if;
end $$;

-- ---- relógio do silêncio só conta interação (migration 0079) ----
-- 0079 — o relógio do silêncio para de ser zerado pela constatação do silêncio
--
-- O DEFEITO, medido antes de escrever: `fn_update_last_activity_at` carimba
-- `crm_leads.last_activity_at` para QUALQUER atividade, sem filtro de tipo. E
-- `last_activity_at` é exatamente o relógio que decide o esfriamento. Então o
-- produtor do estado apagaria o próprio estado ao registrá-lo: o negócio esfria,
-- o sistema registra "esfriou", o trigger zera o relógio, e o negócio volta a
-- "em dia" no mesmo instante. Vinte e quatro horas depois, de novo — uma linha
-- de timeline por janela, para sempre, sem ninguém ter feito nada.
--
-- Provado em transação revertida (lead 08b70b48, o mais frio com relógio
-- não-nulo): 484h de silêncio, bucket CRÍTICO → insere uma atividade → 0h,
-- bucket "em dia".
--
-- A regra geral: CONSTATAR O SILÊNCIO NÃO É QUEBRAR O SILÊNCIO. Toda métrica do
-- tipo "tempo desde o último X" é aniquilada por registrar observação sobre ela,
-- se o registro contar como X.
--
-- ⚠️ POR QUE LISTA POSITIVA E NÃO LISTA DE EXCEÇÕES — a assimetria é o ponto
-- inteiro, e inverter parece inofensivo:
--
--   com lista de exceções ("ignore lead_cooled"), um tipo NOVO de observação de
--   sistema, daqui a seis meses, volta a carimbar o relógio. O negócio parece
--   vivo estando morto: morte silenciosa, que é a doença que esta wave existe
--   para curar;
--
--   com lista positiva, um tipo novo de interação REAL fica de fora e o negócio
--   parece frio estando quente: alarme falso, visível, alguém reclama e conserta.
--
-- O default para o que ainda não existe tem de ser o erro BARULHENTO.
--
-- AS ESCOLHAS DE FORA, cada uma com sua razão — revisáveis, mas não por
-- distração:
--   send_vetoed        o envio não chegou ao cliente. Se contasse, um negócio em
--                      que a IA tenta e é barrada em looping pareceria vivo
--                      estando travado;
--   handoff_triggered  passar para humano é PROMESSA de atendimento, não
--                      atendimento. Se contasse, o negócio transferido e nunca
--                      atendido ficaria mascarado justamente na janela em que
--                      alguém deveria notar;
--   next_action_dismissed  o humano decidiu NÃO agir. O negócio fica sem próximo
--                      passo, que é a definição de risco na doutrina — deveria
--                      esfriar mais rápido, não menos.

create or replace function public.fn_update_last_activity_at()
  returns trigger
  language plpgsql
  set search_path to 'public', 'pg_temp'
as $function$
begin
  -- LISTA POSITIVA: só isto conta como "alguém tocou este negócio". Tipo que
  -- não está aqui NÃO quebra o silêncio — inclusive tipo que ainda não existe.
  -- Ver o cabeçalho da 0079 antes de acrescentar linha nesta lista.
  if new.type not in (
    'ai_turn',              -- a IA falou com o cliente
    'note',                 -- alguém registrou trabalho no negócio
    'lead_edited',          -- humano mexeu nos dados
    'stage_changed',        -- humano moveu o negócio
    'next_action_approved'  -- humano decidiu agir
  ) then
    return new;
  end if;

  update public.crm_leads
     set last_activity_at = greatest(coalesce(last_activity_at, '-infinity'::timestamptz), new.performed_at)
   where id = new.lead_id;

  if new.contact_id is not null then
    update public.contacts
       set last_activity_at = greatest(coalesce(last_activity_at, '-infinity'::timestamptz), new.performed_at)
     where id = new.contact_id;
  end if;
  return new;
end$function$;

comment on function public.fn_update_last_activity_at() is
  'Carimba last_activity_at SÓ para tipos que contam como interação (lista positiva — ver migration 0079). Constatar o silêncio não é quebrar o silêncio: sem este filtro, a atividade que registra "este negócio esfriou" zera o próprio relógio que produziu o estado.';

-- ---- kind de caixa para o acervo de risco (migration 0080) ----
-- 0080 — o acervo de negócios já frios ganha UM item de caixa, com ação nomeada
--
-- POR QUE ISTO EXISTE: quando o estado de risco (0078) começa a ser gravado, os
-- negócios que JÁ estavam frios entram todos de uma vez. Medido no banco de
-- desenvolvimento: 48 críticos e 2 em risco, de 66 abertos.
--
-- Eles NÃO podem emitir atividade de timeline ("esfriou agora" seria falso: eles
-- esfriaram há dias) e não podem entrar em silêncio, porque aí ficariam
-- absolvidos por decreto de migração — cinquenta demandas abertas que ninguém
-- decidiu abandonar e ninguém vai revisar. O `event_log` sozinho não resolve:
-- é rastro de máquina, e não coloca ninguém para agir.
--
-- Daí UM item agregado (não cinquenta) com dono e AÇÃO NOMEADA. Item de caixa
-- sem ação nomeada é o ruído que a própria doutrina proíbe: "revise os 48 e
-- decida quais encerrar" é trabalho; "48 negócios em risco" é um número.
--
-- ⚠️ O `InboxKind` em `lib/agent-engine/db/repository.ts` é a outra ponta deste
-- CHECK e JÁ FICOU TRÊS VALORES ATRÁS DO BANCO sem nada falhar. Kind novo aqui
-- = kind novo lá, na mesma mudança. Está sendo feito neste commit.

-- (constraint agent_inbox_items_kind_check: definida uma vez só, no fim deste
--  apêndice — ver "vocabulário completo". 'risk_backlog_seeded' está lá.)

-- ---- detected_at é carimbo do banco (migration 0081) ----
-- 0081 — `detected_at` deixa de ser dado do cliente e vira CARIMBO do banco
--
-- O DEFEITO, encontrado rodando o observador de travessia (peça 5) e não por
-- inspeção: `since` deriva de `last_activity_at`, que o trigger carimba com o
-- `now()` do BANCO. `detected_at` vinha do processo Node. Medido nesta máquina:
-- **o banco está 2 segundos à frente**. Um negócio tocado no instante anterior à
-- passada do worker produzia `since > detected_at`, violava
-- `crm_lead_risk_states_since_no_passado`, e o worker INTEIRO abortava.
--
-- Omitir a coluna no `upsert` NÃO resolve, e é o detalhe que engana: o default
-- só se aplica no INSERT. No UPDATE — que é o caminho de toda travessia depois
-- da primeira — a coluna mantém o valor ANTIGO, e aí o `since` novo fica maior
-- que um `detected_at` de dias atrás. Pior que o caso do relógio: acontece
-- SEMPRE, não só na janela de dois segundos.
--
-- A constraint estava certa e pegou o que eu não teria visto. O conserto não é
-- afrouxá-la: é tirar do cliente a chance de errar. `detected_at` passa a ser
-- carimbado pelo banco em TODA escrita, como `updated_at` — quem escreve não
-- decide quando percebeu, o banco decide.
--
-- ⚠️ A LIÇÃO É MAIOR QUE A COLUNA: `since` e `detected_at` são comparados por um
-- CHECK, então TÊM de vir do mesmo relógio. O relógio do processo continua
-- classificando (`classifyRisk` compara janelas de HORAS, onde segundos não
-- mudam bucket); o CHECK compara INSTANTES, onde mudam. Grandezas diferentes
-- toleram precisões diferentes, e confundir as duas foi exatamente o defeito.

create or replace function public.fn_carimba_detected_at()
  returns trigger
  language plpgsql
  set search_path to 'public', 'pg_temp'
as $function$
begin
  new.detected_at := now();
  new.updated_at := now();
  return new;
end$function$;

comment on function public.fn_carimba_detected_at() is
  'detected_at é quando o BANCO percebeu, nunca quando o processo achou que percebeu. Ver migration 0081: com o valor vindo do cliente, a deriva de relógio violava o CHECK since <= detected_at e derrubava o worker inteiro.';

drop trigger if exists trg_crm_lead_risk_states_detected_at on public.crm_lead_risk_states;
create trigger trg_crm_lead_risk_states_detected_at
  before insert or update on public.crm_lead_risk_states
  for each row
  execute function public.fn_carimba_detected_at();

-- ---- proposta de reativação com prazo (migration 0082) ----
-- 0082 — a proposta de reativação, com PRAZO e destino
--
-- O cenário 23 fecha o ciclo da wave 7: o negócio esfria (0078-0081), alguém
-- decide reativá-lo, o agente envia, a atividade fica registrada e o estado
-- volta ao normal.
--
-- ⚠️ O BLOCO OBRIGATÓRIO, e ele é RECURSIVO: a wave existe para "esfriando"
-- virar DEMANDA, e a demanda que ela cria TAMBÉM PODE MORRER. Proposta de
-- reativação que ninguém decide fica pendente para sempre, e o negócio volta a
-- ser card parado AGORA COM UM BOTÃO EM CIMA — que é pior que antes: card
-- parado sem nada se lê como abandono; com proposta pendente SIMULA ATENÇÃO, e
-- simulação de atendimento ADIA a intervenção humana em vez de provocá-la.
--
-- Daí `expires_at` ser NOT NULL: não existe proposta sem prazo nesta tabela, e
-- é o banco que garante. No vencimento ela sai do card e vira item de caixa —
-- demanda sem dono não mora no Kanban.
--
-- ⚠️ POR QUE NÃO REUSAR `lead_state.next_action`: ela é por CONTATO (unique
-- organization_id, contact_id) e o risco é por NEGÓCIO — um contato com dois
-- negócios, um esfriando e outro quente, teria uma proposta só para os dois. E
-- é texto livre, sem estado nem prazo. Caberia à força, distorcendo as duas
-- coisas; a decisão é registrada aqui para ninguém "simplificar" depois.
--
-- ⚠️ O ENVIO NÃO NASCE AQUI. Aceitar a proposta dispara o caminho que já existe
-- (`cron_jobs` + o motor de follow-up). Esta tabela guarda a DECISÃO, não a
-- mensagem — criar um segundo caminho de envio seria o mesmo erro de ter duas
-- definições de "esfriando".

create table if not exists public.crm_lead_reactivations (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.crm_leads(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  status text not null default 'pending',
  -- Carimbados pelo BANCO, nunca pelo processo: a 0081 custou um worker
  -- abortando inteiro porque `since` vinha do banco e `detected_at` do Node,
  -- com 2 segundos de deriva entre eles. Instantes comparados entre si vêm do
  -- mesmo relógio.
  proposed_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- O texto que o agente enviaria. É proposta do AGENTE — texto de máquina —,
  -- não campo do negócio: vale a mesma regra do `reason` da timeline, e nenhum
  -- dado do lead entra aqui por cópia.
  draft text,
  decided_at timestamptz,
  decided_by_user_id uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table public.crm_lead_reactivations is
  'Proposta de reativação de negócio esfriado (wave 7, cenário 23). SEMPRE com prazo: proposta que ninguém decide vira card parado com botão em cima, que simula atenção e adia a intervenção humana. No vencimento sai do card e vira item de caixa.';

alter table public.crm_lead_reactivations
  drop constraint if exists crm_lead_reactivations_status_check;
alter table public.crm_lead_reactivations
  add constraint crm_lead_reactivations_status_check check (
    status = any (array['pending', 'accepted', 'dismissed', 'expired']::text[])
  );

-- Prazo no futuro em relação à proposta. Trava o erro de nascer vencida — que
-- criaria um item de caixa no primeiro tick e ninguém entenderia de onde veio.
alter table public.crm_lead_reactivations
  drop constraint if exists crm_lead_reactivations_prazo_no_futuro;
alter table public.crm_lead_reactivations
  add constraint crm_lead_reactivations_prazo_no_futuro check (expires_at > proposed_at);

-- Decisão e decisor andam juntos: status decidido SEM `decided_at` é registro
-- que não sabe dizer quando aconteceu, e a timeline depende dessa resposta.
alter table public.crm_lead_reactivations
  drop constraint if exists crm_lead_reactivations_decisao_datada;
alter table public.crm_lead_reactivations
  add constraint crm_lead_reactivations_decisao_datada check (
    (status = 'pending' and decided_at is null)
    or (status <> 'pending' and decided_at is not null)
  );

-- UMA proposta viva por negócio. Índice parcial: propostas já decididas ficam
-- como histórico e não bloqueiam a próxima — o negócio pode esfriar de novo, e
-- impedir isso deixaria o segundo esfriamento sem proposta nenhuma.
create unique index if not exists uq_crm_lead_reactivations_uma_viva
  on public.crm_lead_reactivations (lead_id)
  where status = 'pending';

-- O worker de vencimento varre por aqui.
create index if not exists idx_crm_lead_reactivations_vencendo
  on public.crm_lead_reactivations (organization_id, expires_at)
  where status = 'pending';

alter table public.crm_lead_reactivations enable row level security;

drop policy if exists tenant_isolation_crm_lead_reactivations_all on public.crm_lead_reactivations;
create policy tenant_isolation_crm_lead_reactivations_all on public.crm_lead_reactivations
  for all
  using (organization_id in (select fn_user_org_ids()))
  with check (organization_id in (select fn_user_org_ids()));

-- `proposed_at` e `updated_at` são do banco, como na 0081.
create or replace function public.fn_carimba_reativacao()
  returns trigger
  language plpgsql
  set search_path to 'public', 'pg_temp'
as $function$
begin
  if tg_op = 'INSERT' then
    new.proposed_at := now();
  end if;
  new.updated_at := now();
  return new;
end$function$;

drop trigger if exists trg_crm_lead_reactivations_carimbo on public.crm_lead_reactivations;
create trigger trg_crm_lead_reactivations_carimbo
  before insert or update on public.crm_lead_reactivations
  for each row
  execute function public.fn_carimba_reativacao();

-- DENTRO da publicação de realtime, pela mesma regra da 0078: proposta nascendo
-- ou vencendo é MUDANÇA DE ESTADO que o card precisa mostrar sem reload —
-- não é telemetria.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'crm_lead_reactivations'
  ) then
    execute 'alter publication supabase_realtime add table public.crm_lead_reactivations';
  end if;
end $$;

-- ---- kind de caixa para reativação vencida (migration 0083) ----
-- 0083 — a proposta de reativação vencida tem PARA ONDE IR
--
-- Sem este kind, o vencimento seria uma linha de banco e nada mais: a proposta
-- sai do card e desaparece. "Some do card" resolve a simulação de atenção e
-- cria o problema anterior de volta — o negócio parado sem ninguém sabendo.
--
-- A demanda que a wave criou não pode morrer por silêncio, e é EXATAMENTE a
-- mesma forma da promessa cujo prazo depende de terceiro: sem fallback
-- declarado, ela não é quebrada por decisão — ELA EXPIRA SOZINHA E NINGUÉM
-- PERCEBE QUE DECIDIU. O item de caixa é o fallback, e ele tem dono e ação
-- nomeada porque item sem ação é o ruído que a doutrina proíbe.
--
-- ⚠️ O `InboxKind` em `lib/agent-engine/db/repository.ts` e o
-- `Record<InboxKind, string>` em `lib/ai/agent-inbox-copy.ts` são as outras
-- pontas deste CHECK. Kind novo aqui = kind novo nos dois, no mesmo commit —
-- e agora o invariante `vocabulario-banco-x-typescript` LÊ o arquivo de
-- verdade, então esquecer não passa mais em silêncio.

-- (constraint agent_inbox_items_kind_check: definida uma vez só, no fim deste
--  apêndice — ver "vocabulário completo". 'reactivation_expired' está lá.)

-- ---- agent_stage_hint (migration 0084) ----
-- 0084 — o funil do AGENTE aprende a falar o vocabulário do TENANT
--
-- Dois vocabulários que hoje não se conhecem:
--
--   AGENTE    `lead_state.stage` — SETE valores fixos: new, contacted,
--             qualifying, qualified, negotiating, won, lost;
--   PIPELINE  `crm_stages` — arbitrários por tenant. Medidos neste banco:
--             clínica  → Primeiro contato, Avaliação, Proposta enviada,
--                        Negociação, Tratamento fechado, Perdido
--             e-commerce → Carrinho abandonado, Aguardando pagamento, Pago,
--                        Em separação, Enviado, Entregue, Pós-venda, Cancelado
--
-- Sem ponte, o agente que avança o próprio funil não move o card — e o board
-- mostra um negócio parado num estágio que já não é verdade.
--
-- ⚠️ E A PONTE JÁ EXISTE PELA METADE: `crm_stages` tem `is_won` e `is_lost`.
-- Dois dos sete já estão mapeados, por colunas booleanas. Esta migration NÃO
-- cria um mecanismo novo — GENERALIZA um que existe incompleto. A consequência
-- é o CHECK de coerência abaixo: sem ele, `is_won` e `agent_stage_hint`
-- passariam a ser DUAS FONTES capazes de dizer coisas diferentes sobre o mesmo
-- estágio, que é a família de defeito que esta entrega inteira encontrou seis
-- vezes ("um lado mudou e o outro não acompanhou").
--
-- `null` é estado LEGÍTIMO e comum: "Em separação", "Pós-venda" e "Carrinho
-- abandonado" não têm equivalente no funil do agente, e forçar um mapeamento
-- seria inventar semântica que o tenant não declarou.

alter table public.crm_stages
  add column if not exists agent_stage_hint text;

comment on column public.crm_stages.agent_stage_hint is
  'A que passo do funil do AGENTE este estágio corresponde (lead_state.stage). NULL = não corresponde a nenhum, que é legítimo. Coerente com is_won/is_lost por CHECK — ver migration 0084.';

alter table public.crm_stages
  drop constraint if exists crm_stages_agent_stage_hint_check;
alter table public.crm_stages
  add constraint crm_stages_agent_stage_hint_check check (
    agent_stage_hint is null
    or agent_stage_hint = any (array[
      'new', 'contacted', 'qualifying', 'qualified', 'negotiating', 'won', 'lost'
    ]::text[])
  );

-- ⚠️ A COERÊNCIA COM O QUE JÁ EXISTIA. Um estágio marcado `is_won` que se
-- anuncia como 'qualifying' faria o agente e o board discordarem sobre o mesmo
-- lugar — e cada um estaria "certo" pela sua própria fonte. O CHECK torna a
-- divergência IMPOSSÍVEL em vez de improvável.
--
-- Nos dois sentidos, de propósito: `is_won` sem hint é o estado de hoje (válido,
-- e é como todos os clones começam), mas hint='won' num estágio que não é de
-- ganho seria mentira na direção oposta.
alter table public.crm_stages
  drop constraint if exists crm_stages_hint_coerente_com_won_lost;
alter table public.crm_stages
  add constraint crm_stages_hint_coerente_com_won_lost check (
    (agent_stage_hint <> 'won' or is_won)
    and (agent_stage_hint <> 'lost' or is_lost)
    and (not is_won or agent_stage_hint is null or agent_stage_hint = 'won')
    and (not is_lost or agent_stage_hint is null or agent_stage_hint = 'lost')
  );

-- ⚠️ UM ESTÁGIO POR HINT, POR PIPELINE — e este índice é UNIQUE de propósito.
--
-- Eu ia tratar a ambiguidade no resolvedor ("dois estágios com o mesmo hint →
-- recuse mover"). O schema já respondeu melhor: `uniq_crm_stages_pipeline_won` e
-- `uniq_crm_stages_pipeline_lost` JÁ EXISTEM, com o mesmo desenho — parcial, e
-- excluindo arquivados. O produto já decidiu que "dois lugares de ganho no mesmo
-- funil" é impossível, não improvável; não havia razão para os outros cinco
-- passos serem tratados com menos rigor que os dois.
--
-- E a diferença é grande: com o UNIQUE, o tenant DESCOBRE o erro ao configurar
-- — o banco recusa na hora, com o estágio na frente dele. Com tratamento no
-- resolvedor, ele descobriria meses depois, quando um negócio não se movesse e
-- ninguém soubesse dizer por quê.
--
-- `is_archived = false` acompanha o precedente: estágio arquivado é histórico e
-- não disputa o mapeamento com o que está em uso.
create unique index if not exists uniq_crm_stages_pipeline_hint
  on public.crm_stages (pipeline_id, agent_stage_hint)
  where agent_stage_hint is not null and is_archived = false;

-- ---- backfill do que JÁ ESTÁ DECIDIDO, e só dele ----
-- `is_won`/`is_lost` são declaração explícita do tenant sobre aquele estágio;
-- copiá-los para o hint não inventa nada. NENHUM outro estágio é adivinhado:
-- inferir 'qualifying' de um nome como "Avaliação" seria o sistema decidindo
-- semântica por semelhança de palavra, e erraria em português de outro nicho.
update public.crm_stages
   set agent_stage_hint = 'won'
 where is_won and agent_stage_hint is null;

update public.crm_stages
   set agent_stage_hint = 'lost'
 where is_lost and agent_stage_hint is null;

-- ANALYZE: `ALTER TABLE` deixa o planner sem estatística e ele passa a errar a
-- escolha de índice em consultas de crm_leads (medido no G4-04). Custa
-- milissegundos numa tabela vazia.
analyze public.crm_leads;
-- ---- intent router: ai_routers/members/decisions + stickiness (migration 0085) ----

-- 0085: Intent Router (Fase 3 do épico harness — spec 2026-07-23).
-- Um router pluga num channel_session e roteia a conversa para o agente cuja
-- intenção declarada casa com a mensagem. Tabelas EDITÁVEIS (não versão+ponteiro):
-- mutação é au…62152 tokens truncated…na DIRC: Duplicar, não
  -- Referenciar):
  --  · `conversation_id`: a policy de SELECT precisa da conversa SEM passar
  --    por `agent_cases`, cuja policy é org-wide e reintroduziria exatamente o
  --    vazamento que esta feature fecha;
  --  · `contact_id`: é a FK que põe a tabela no escopo do invariante de LGPD e
  --    o filtro que a redação e o export usam. Sem ela, anonimizar devolveria
  --    sucesso com a conversa legível, e nenhum gate acusaria.
  conversation_id  uuid not null references public.conversations(id) on delete cascade,
  contact_id       uuid not null references public.contacts(id)      on delete cascade,
  -- Agrupa pergunta + resposta. GERADO NO CLIENTE: é ele que dá a idempotência
  -- sem copiar a resposta para `idempotency_keys` (ver a unique lá embaixo).
  turn_id          uuid not null,
  author_kind      text not null check (author_kind in ('human','ai')),
  -- `on delete set null`: a saída de uma pessoa do sistema não apaga o que ela
  -- perguntou. Por isso NÃO existe check acoplando `author_kind` a
  -- `author_user_id` — ele quebraria o próprio `set null`.
  author_user_id   uuid references auth.users(id) on delete set null,
  -- null quando a resposta falhou, ou quando a redação de LGPD passou por aqui.
  body             text,
  -- null = deu certo. NÃO existe coluna `status`: ela seria a segunda
  -- representação do mesmo fato (anti-pattern 2 do CLAUDE.md).
  error_code       text,
  -- Quem RESPONDEU de fato. null = respondeu a persona padrão da organização
  -- (agente do caso ausente, arquivado, pausado ou despublicado). A persona "de
  -- agora" é recalculada a cada requisição; esta coluna é o registro histórico.
  agent_id         uuid references public.ai_agents(id)  on delete set null,
  llm_call_id      uuid references public.llm_calls(id)  on delete set null,
  -- O atendimento que originou o caso já tinha mudado quando esta resposta foi
  -- dada. Mesmo vocabulário do audit da rota de resposta ao caso.
  service_stale    boolean not null default false,
  redacted_at      timestamptz,
  created_at       timestamptz not null default now(),
  -- A IDEMPOTÊNCIA DO POST, no banco e NÃO em `idempotency_keys`: o helper
  -- `comIdempotencia` grava `response_body` (lib/api/idempotency.ts), que seria
  -- uma cópia da resposta sobre a pessoa numa tabela FORA da cascata de LGPD e
  -- SEM expurgo nenhum (`grep -rn "idempotency_keys" app/api/v1/cron lib/retencao
  -- lib/lgpd` → vazio). Esta unique resolve o clique duplo E a corrida que o
  -- próprio helper declara não cobrir.
  constraint agent_case_chat_messages_turno_unico
    unique (organization_id, case_id, turn_id, author_kind)
);

-- Auto-cura para o clone que já tenha uma versão ANTERIOR da tabela: o
-- `create table if not exists` acima é no-op ali. Só as colunas que podem ser
-- acrescentadas a uma tabela COM LINHAS entram — as `not null` sem default não
-- podem, e não precisam: a tabela nasce aqui, então nenhum clone tem uma forma
-- anterior dela sem elas.
alter table public.agent_case_chat_messages add column if not exists author_user_id uuid;
alter table public.agent_case_chat_messages add column if not exists body text;
alter table public.agent_case_chat_messages add column if not exists error_code text;
alter table public.agent_case_chat_messages add column if not exists agent_id uuid;
alter table public.agent_case_chat_messages add column if not exists llm_call_id uuid;
alter table public.agent_case_chat_messages add column if not exists service_stale boolean not null default false;
alter table public.agent_case_chat_messages add column if not exists redacted_at timestamptz;

-- O CHECK e a unique em bloco próprio, para o clone que tenha a tabela sem
-- eles. `drop` + `add` é auto-curativo; a tabela nasce vazia, então não há dado
-- a corrigir antes (a regra 8 da doutrina de migrations).
alter table public.agent_case_chat_messages
  drop constraint if exists agent_case_chat_messages_author_kind_check;
alter table public.agent_case_chat_messages
  add constraint agent_case_chat_messages_author_kind_check
  check (author_kind in ('human','ai'));

alter table public.agent_case_chat_messages
  drop constraint if exists agent_case_chat_messages_turno_unico;
alter table public.agent_case_chat_messages
  add constraint agent_case_chat_messages_turno_unico
  unique (organization_id, case_id, turn_id, author_kind);

-- Três índices, um propósito cada, e nenhum é prefixo de outro (a memória da
-- 0259: índice redundante sai).
create index if not exists agent_case_chat_messages_case_idx
  on public.agent_case_chat_messages (organization_id, case_id, created_at);
-- Redação e export só procuram o que ainda é legível.
create index if not exists agent_case_chat_messages_contact_idx
  on public.agent_case_chat_messages (organization_id, contact_id)
  where redacted_at is null;
-- O expurgo ordena por `created_at`.
create index if not exists agent_case_chat_messages_purga_idx
  on public.agent_case_chat_messages (created_at);

alter table public.agent_case_chat_messages enable row level security;

-- ── Privilégio: leitura pelo login, escrita SÓ pelo servidor ───────────────
-- `revoke all` PRIMEIRO porque o `ALTER DEFAULT PRIVILEGES … GRANT ALL ON
-- TABLES TO "authenticated"` do baseline vem ANTES de toda tabela de apêndice:
-- sem o revoke, a tabela nasce com INSERT/UPDATE/DELETE para `authenticated` e
-- a policy seria a única coisa entre um `viewer` e a escrita. Mesmo desenho de
-- `ai_reply_drafts` (0227) e das três tabelas da 0279.
revoke all    on public.agent_case_chat_messages from anon, authenticated;
grant  select on public.agent_case_chat_messages to authenticated;
grant  all    on public.agent_case_chat_messages to service_role;

-- ── RLS: organização + papel + VISIBILIDADE DA CONVERSA ───────────────────
-- A terceira condição é a razão de a tabela carregar `conversation_id` dentro.
-- `fn_can_view_conversation` restringe SÓ o papel `agent`: viewer/manager/admin
-- leem tudo por desenho, que é a decisão do dono do produto. Policy POR COMANDO
-- (`for select`), nunca `for all` — e aqui nem se trata disso: não existe
-- caminho de escrita pelo PostgREST, porque o `revoke` acima o fechou.
drop policy if exists tenant_isolation_agent_case_chat_messages_select on public.agent_case_chat_messages;
create policy tenant_isolation_agent_case_chat_messages_select
  on public.agent_case_chat_messages
  for select to authenticated
  using (
    organization_id in (select public.fn_user_org_ids())
    and public.fn_role_at_least(organization_id, 'agent')
    and exists (
      select 1
        from public.conversations c
       where c.organization_id = agent_case_chat_messages.organization_id
         and c.id = agent_case_chat_messages.conversation_id
         and public.fn_can_view_conversation(c.organization_id, c.assigned_to_user_id)
    )
  );

-- ── Retenção: a tabela nasce com dono de piso ─────────────────────────────
create or replace function public.fn_expurgar_conversa_do_caso_vencida(
  p_retencao_dias int default null,
  p_limite int default null
) returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- 365 = um ano fiscal: depois disso, "por que decidimos assim" é respondido
  -- pelos EVENTOS do caso, não pela deliberação que os precedeu. O piso de 90
  -- impede que o knob vire apagador de rastro recente — o mesmo piso da
  -- auditoria, e pela mesma razão. O piso mora AQUI, no corpo, porque só assim
  -- ele vale para QUALQUER chamador, inclusive um `psql` na mão.
  v_dias int := greatest(coalesce(p_retencao_dias, 365), 90);
  v_limite int := least(greatest(coalesce(p_limite, 1000), 1), 10000);
  v_apagadas int;
begin
  with vencidas as (
    select m.id from public.agent_case_chat_messages m
     where m.created_at < now() - make_interval(days => v_dias)
     order by m.created_at
     limit v_limite
  )
  delete from public.agent_case_chat_messages m using vencidas v where m.id = v.id;
  get diagnostics v_apagadas = row_count;
  return v_apagadas;
end;
$$;
-- As DUAS origens de EXECUTE: o `ALTER DEFAULT PRIVILEGES … GRANT ALL ON
-- FUNCTIONS TO anon` do baseline (que `revoke from public` não remove) e o
-- grant implícito a PUBLIC que o Postgres dá a toda função ao criá-la (que
-- `revoke from anon` não remove). Fechar uma só deixa a função exposta com o
-- gate verde.
revoke all    on function public.fn_expurgar_conversa_do_caso_vencida(int,int) from public, anon, authenticated;
grant  execute on function public.fn_expurgar_conversa_do_caso_vencida(int,int) to service_role;

-- ── A cascata de LGPD alcança a conversa do caso ──────────────────────────
-- Derivada do corpo VIGENTE do baseline (a definição de maior número de linha),
-- por script, nunca redigitada: o corpo anterior fica byte a byte igual e o
-- único acréscimo é o passo de `agent_case_chat_messages`. O Postgres troca o
-- corpo INTEIRO num `create or replace` — quem derivar da versão errada apaga
-- o passo de outra entrega sem um único erro. A catraca que vigia isso é
-- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
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
  perform public.fn_service_lock(p_organization_id,p_contact_id);
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

  -- 7b. voice_calls — o TELEFONE de quem falou ao telefone (migration 0235).
  --
  -- `peer_phone` é `not null` e guarda o número da outra ponta: depois de
  -- anonimizar o contato, ele sobrevivia ligado ao `contact_id` e reidentificava
  -- a pessoa que pediu para ser esquecida. É o mesmo argumento que a foto de
  -- perfil já tinha (ver o bloco do avatar em `lib/lgpd/redact-cascade.ts`):
  -- anonimizar em toda parte menos numa é não ter anonimizado.
  --
  -- O que fica: direção, status, motivo do fim, marcas de tempo e duração. Um
  -- registro de "houve uma chamada de 12 minutos" sem número e sem dono não
  -- identifica ninguém e é o que sustenta a métrica do atendente e a fatura.
  -- `peer_phone` é NOT NULL, então recebe o rótulo, não `null`.
  update voice_calls set
    peer_phone = v_anon_label,
    owner_user_id = null,
    created_by = null,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('voice_calls', v_count);

  -- agent_cases — o que a IA escreveu SOBRE a pessoa quando travou (migration 0280).
  --
  -- O caso é o texto que a equipe lê antes de decidir: `title`, `summary` e
  -- `blocker` saem do modelo a partir da conversa, e `context_snapshot` é o
  -- recorte dessa conversa que o motor mandou para ele. Nada disso é registro de
  -- operação — é o relato do problema de uma pessoa identificável, escrito por
  -- máquina. Sem este passo, anonimizar devolvia SUCESSO com o relato intacto.
  --
  -- As três colunas de texto são `not null`: recebem rótulo e texto fixo, nunca
  -- `null` (a mesma razão de `voice_calls.peer_phone` logo acima).
  --
  -- ⚠️ `updated_at` FICA FORA DO `set`, de propósito. O cobrador de caso parado
  -- (`app/api/v1/cron/case-stale-watcher/route.ts`) lê `updated_at` como "alguém
  -- da equipe encostou neste caso". A cascata não é alguém encostando: escrever
  -- ali faria a anonimização ADIAR a cobrança de um caso que continua parado, e
  -- o efeito só apareceria como um cliente esperando mais tempo.
  --
  -- O vínculo é pela CONVERSA porque `agent_cases` não tem FK para `contacts`.
  update agent_cases set
    title = v_anon_label,
    summary = '[resumo anonimizado]',
    blocker = '[bloqueio anonimizado]',
    context_snapshot = '{}'::jsonb
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_cases', v_count);

  -- agent_case_events — a linha do tempo do caso (migration 0280).
  --
  -- `body` é o que a pessoa da equipe escreveu ao responder o caso e o que o
  -- agente registrou sobre o que o LEAD respondeu; `metadata` carrega o recorte
  -- que o motor anexou. `kind`, `actor_kind`, `human_action` e `created_at`
  -- FICAM: são o registro de que houve um toque humano e quando — operação, não
  -- dado da pessoa, e é deles que sai a métrica de atendimento.
  update agent_case_events set
    body = null,
    metadata = '{}'::jsonb
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_events', v_count);

  -- demandas — o assunto do pedido (migration 0280).
  --
  -- `assunto` é texto livre sobre o que a pessoa pediu. O resto da linha é a
  -- operação da demanda (origem, estado, dono, prazo, desfecho) e fica de pé:
  -- apagar a linha inteira tiraria da organização a resposta a "quantos pedidos
  -- houve em março", que é o mesmo argumento do compromisso da agenda.
  --
  -- FK direta (`demandas.contact_id` é `not null`), então o vínculo é o contato.
  update demandas set
    assunto = null
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('demandas', v_count);

  -- agent_inbox_items — o aviso que leva o texto do caso para a Central (migration 0280).
  --
  -- O `body` do aviso de caso parado EMBUTE o título do caso
  -- (`app/api/v1/cron/case-stale-watcher/route.ts:128`), e o do handoff embute o
  -- motivo da parada (`lib/ai/handoff/orchestrator.ts:335`). Redigir o caso e
  -- deixar o aviso de pé seria anonimizar em toda parte menos numa — que é não
  -- ter anonimizado. O molde (resolver + trocar o corpo + soltar a referência) é
  -- o de `fn_meet_redact_contact`, que já faz isto para o aviso de compromisso.
  --
  -- ⚠️ O VÍNCULO É POLIMÓRFICO E TEM TRÊS BRAÇOS, não dois. Medido nos
  -- produtores, não suposto: `handoff` nasce com `ref_kind='contact'`
  -- (`lib/ai/handoff/orchestrator.ts:339`) E com `ref_kind='conversation'`
  -- (`lib/agent-engine/agent/inbound-turn.ts:4100`); `case_stale` nasce SEMPRE
  -- com `ref_kind='agent_case'` (a rota do cron acima, e a política em
  -- `lib/ai/inbox-destino.ts:38`). Um predicado com só os dois primeiros braços
  -- casa ZERO avisos de caso parado — e casar zero linha não é erro: é sucesso
  -- com o texto intacto.
  --
  -- Os `kind` são os MEDIDOS no CHECK vigente (`supabase/baseline.sql`, bloco
  -- único de `agent_inbox_items_kind_check`). `case_opened` NÃO existe, e kind
  -- inexistente num `in (...)` também casa zero e devolve sucesso. Para
  -- reconferir sem acreditar nesta prosa:
  --   grep -n "agent_inbox_items_kind_check check" -A40 supabase/baseline.sql
  update agent_inbox_items set
    status = 'resolved',
    resolved_at = now(),
    body = 'Contato anonimizado.',
    ref_id = null
  where organization_id = p_organization_id
    and kind in ('handoff', 'case_stale')
    and (
      (ref_kind = 'contact' and ref_id = p_contact_id)
      or (ref_kind = 'conversation' and ref_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          ))
      or (ref_kind = 'agent_case' and ref_id in (
            select id from agent_cases
              where organization_id = p_organization_id
                and conversation_id in (
                  select id from conversations
                    where contact_id = p_contact_id and organization_id = p_organization_id
                )
          ))
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_inbox_items', v_count);

  -- agent_case_chat_messages — a consulta interna da equipe à IA SOBRE o caso
  -- (migration 0281). FK DIRETA para `contacts`, então o vínculo é o titular e
  -- não precisa passar pela conversa.
  --
  -- `redacted_at is null` no `where` é o que torna o passo IDEMPOTENTE: a
  -- varredura diária de redações incompletas roda a função de novo, e sem essa
  -- condição o carimbo de QUANDO se apagou seria reescrito a cada rodada.
  --
  -- A linha NÃO é apagada, só o texto: quem abrir o caso depois continua vendo
  -- que a equipe perguntou N vezes, quando, e se a IA respondeu. Apagar a linha
  -- inteira ficaria verde num teste de "o texto sumiu" e tiraria da organização
  -- a resposta a "quanto a equipe deliberou sobre este caso".
  update agent_case_chat_messages set
    body = null,
    redacted_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id
    and redacted_at is null;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_chat_messages', v_count);

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

-- ── travas do suporte, depois de toda tabela nova (migration 0274) ─────────
-- `agent_case_chat_messages` nasce SERVER-ONLY (revoke de anon/authenticated +
-- grant select), então o ramo server-only da função lhe dá ZERO policies
-- `support_write_*` — que é o contrato mais restritivo. Escrever `drop policy`
-- à mão aqui seria a segunda representação da mesma regra.
do $f$ begin perform public.fn_aplicar_travas_de_suporte(); end $f$;

notify pgrst, 'reload schema';



-- ---- a passagem para uma pessoa vira um fato com registro (migration 0291) ----
-- 0291 — A passagem do atendimento para uma pessoa vira um FATO com registro.
--
-- ─── O que se perdia, e onde ──────────────────────────────────────────────
--
-- Existem dois motores que tiram a conversa do automático: `performHumanHandoff`
-- (`lib/agent-engine`, `pg.Pool`) e `triggerHandoff` (`lib/ai/handoff`,
-- supabase-js). O primeiro monta um resumo do checkpoint e o enfia no corpo do
-- aviso da Central; o segundo abre o aviso SEM resumo nenhum. Em nenhum dos dois
-- sobrevive o que a pessoa que assume precisa: POR QUE a IA passou, o que ela já
-- tentou, o que o cliente pediu com as palavras dele, e se ele chegou a ser
-- avisado de que alguém vai responder.
--
-- O resultado, medido em conversa real: quem assume relê a conversa inteira e
-- repete as perguntas que a IA já fez. O cliente responde duas vezes. É esse o
-- laço de retorno desta entrega — se o briefing chegou, a repetição cai; se não
-- chegou, ela não muda e a feature é decoração.
--
-- ─── POR QUE TABELA PRÓPRIA, e não um veículo que já existe ───────────────
--
-- `crm_lead_activities.reason` é o candidato óbvio (a transferência manual já o
-- usa), e as três razões de ele não servir foram medidas antes:
--
--   1. a coluna é declarada "O PORQUÊ, legível por humano. Sem PII" em
--      `lib/leads/activity-emitter.ts`, e é por isso que `performHumanHandoff`
--      grava ali o texto FIXO "Atendimento passado para uma pessoa". O briefing
--      é resumo de conversa: é PII por construção;
--   2. a atividade é roteada para um NEGÓCIO ABERTO (`emitAgentActivityForContact`)
--      e sem negócio ela não nasce — passagem sem lead existiria e seria invisível;
--   3. o registro precisa de ESTADO (`reconhecido_por`/`reconhecido_em`) e de
--      estrutura (as tentativas). `crm_lead_activities` não tem onde pôr isso sem
--      virar `jsonb` lido por path, que é o anti-pattern nº 6 do CLAUDE.md.
--
-- ─── POR QUE AS COLUNAS SE CHAMAM `title`/`body`/`notes`/`content` ────────
--
-- De propósito, e não por gosto — é a mesma escolha da 0281.
-- `tests/invariants/lgpd-cascata-alcanca-quem-guarda-pessoa.test.ts` só enxerga
-- a tabela que satisfaz as DUAS condições: FK para `contacts` E coluna cujo NOME
-- case o padrão de PII (`…|notes|note|body|content|title|subject…`). Uma tabela
-- com `resumo`/`motivo_texto`/`cliente_quer` — que foi o desenho anterior —
-- nasceria INVISÍVEL ao gate, e a cobertura dependeria de alguém lembrar de um
-- invariante comportamental que uma sessão futura pode apagar com o gate de
-- classe verde. Escolher o nome que o instrumento lê é mais barato que ensinar o
-- instrumento a ler outro nome.
--
-- ─── DOUTRINA DIRC, respondida ────────────────────────────────────────────
--
--   Duplicar   — não: motivo, narrativa e tentativas não existem hoje em lugar
--                nenhum (`rg -n -i "o que (já )?tentou|ja_tentou"` → vazio);
--   Integrar   — `contact_id`/`conversation_id`/`caso_id` são FK, não cópias;
--   Referenciar— `motor`/`origem`/`motivo_codigo` são vocabulário fechado;
--   Calcular   — `body` NÃO é calculável depois: ele depende do estado do turno,
--                que não sobrevive ao turno.
--
-- ─── O QUE ESTA MIGRATION FAZ ─────────────────────────────────────────────
--
--   1. cria `public.passagens_de_atendimento` — uma linha por episódio;
--   2. liga a RLS de LEITURA em três condições (organização + papel `agent` +
--      visibilidade da conversa) e deixa a tabela SERVER-ONLY na escrita;
--   3. cria `fn_expurgar_passagens_vencidas` (1825 dias, piso de 90 no CORPO),
--      que o cron diário de retenção passa a chamar — e que NUNCA apaga
--      passagem ainda não reconhecida, porque passagem aberta é demanda viva;
--   4. redefine `fn_lgpd_cascade_redact_contact` com UM passo novo e UMA coluna
--      a mais no passo 2, derivada do corpo VIGENTE (a definição de maior número
--      de linha no `supabase/baseline.sql`, copiada por script — o corpo anterior
--      fica byte a byte igual, exceto pelas duas edições declaradas).
--
-- O que esta migration NÃO faz, declarado: ninguém ESCREVE nesta tabela ainda.
-- Os 13 call sites dos dois motores, o reconhecimento automático por
-- `fn_conversation_assign` e o cartão na conversa são das ondas seguintes. Uma
-- tabela sem escritor é "evento sem consumidor" ao contrário, e a única razão de
-- ela nascer antes é que schema e call site no mesmo PR fazem o reviewer ler
-- 1.500 linhas para julgar uma decisão de modelagem.
--
-- ─── REAPLICAÇÃO ──────────────────────────────────────────────────────────
--
-- `create table if not exists`, `add column if not exists`, `drop constraint if
-- exists` + `add constraint`, `create index if not exists`, `drop policy if
-- exists` + `create policy`, `create or replace function`. O `update.sh` de um
-- clone reaplica sem erro e sem duplicar efeito. Nenhuma constraint nova sobre
-- dados existentes ⇒ não há deduplicação prévia a fazer (regra 8 da doutrina).

create table if not exists public.passagens_de_atendimento (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations(id) on delete cascade,
  -- FK para `contacts`: é ela que põe a tabela no escopo do invariante de LGPD,
  -- e é o filtro que a redação e o export usam.
  contact_id       uuid not null references public.contacts(id)      on delete cascade,
  -- FK para `conversations`: a passagem é da CONVERSA (é onde a pessoa
  -- responde), e é este ponteiro que a RLS usa para herdar
  -- `fn_can_view_conversation` sem passar por nenhuma tabela org-wide.
  conversation_id  uuid not null references public.conversations(id) on delete cascade,
  -- Só quando a passagem nasceu do "Não consigo → escalar" de um caso.
  -- `set null` e NÃO `cascade`: apagar o caso não pode apagar o fato de a
  -- conversa ter ido para uma pessoa.
  caso_id          uuid references public.agent_cases(id)            on delete set null,

  -- Qual dos dois motores passou. Sem esta coluna, "o motor B parou de gravar"
  -- é indistinguível de "ninguém passou conversa nenhuma".
  motor            text not null check (motor in ('engine','crm')),
  -- POR ONDE entrou (o caminho de código), distinto de POR QUE (a razão). O
  -- mesmo `requested_human` chega por três origens, e é a origem que responde
  -- "que parte do sistema decidiu isto?".
  origem           text not null check (origem in (
                     'pedido_explicito','opt_out_provavel','ferramenta_do_modelo',
                     'teto_de_gasto','caso_escalado','sentimento','legado_pedido',
                     'legado_juridico','legado_etapa','legado_confianca','legado_teto',
                     'mcp_externo','runtime_nativo')),
  -- POR QUE saiu do automático. É o que vira FRASE na tela — o código nunca
  -- aparece para uma pessoa (`lib/escalacao/passagem.ts` → `FRASE_DO_MOTIVO`).
  motivo_codigo    text not null check (motivo_codigo in (
                     'requested_human','suspected_optout','orcamento_de_ia','low_sentiment',
                     'low_confidence','critical_stage','legal_mention','refund_mention',
                     'caso_escalado')),

  -- ─── OS QUATRO NOMES QUE O GATE DE LGPD LÊ (ver o cabeçalho) ─────────────
  --   title   ← "o que o cliente quer", em uma linha (é o título do cartão)
  --   body    ← a narrativa montada, que é o que a pessoa lê antes de responder
  --   notes   ← as últimas palavras LITERAIS do cliente (citação, não conclusão)
  --   content ← o texto livre de quem passou (o `por_que` da ferramenta, a razão
  --             humana do caso, o `reason` do MCP). Vem do modelo ou de fora: é
  --             dado NÃO confiável, e por isso é sanitizado antes do insert e
  --             exibido como citação, nunca como instrução.
  title            text,
  -- `not null` porque é o que a tela mostra: um cartão sem corpo afirma que não
  -- há contexto, quando o que houve foi a montagem não ter recebido nada. O piso
  -- mora em `lib/escalacao/briefing-da-passagem.ts` (`PISO_DO_BRIEFING`).
  body             text not null,
  notes            text,
  content          text,

  -- Estruturado, para a lista numerada do cartão. NÃO é "texto livre solto": é
  -- validado por `tentativasDaPassagemSchema` (Zod, `lib/escalacao/passagem.ts`)
  -- ANTES do insert e lido por parser tipado, nunca por path cru — o CHECK aqui
  -- garante só a forma externa, porque é o que um CHECK consegue garantir.
  tentativas       jsonb not null default '[]'::jsonb
                     check (jsonb_typeof(tentativas) = 'array'),

  -- A VERDADE sobre o aviso ao cliente. `null` = ninguém tentou avisar (o
  -- caminho acionado por uma pessoa que já está na conversa e fala por si).
  -- A distinção existe porque a promessa "o cliente JÁ foi avisado" era dita sem
  -- ninguém olhar o desfecho do envio: `sendMessageHandler` devolve `failed` sem
  -- lançar, e o caminho seguinte afirmava `avisado: true`.
  cliente_avisado      boolean,
  -- Vocabulário FECHADO, não texto livre: é a TELA que traduz. Uma frase gravada
  -- em português aqui seria a segunda representação do mesmo fato, e a primeira
  -- a ficar sem espanhol.
  aviso_motivo_codigo  text check (aviso_motivo_codigo is null or aviso_motivo_codigo in (
                         'na_fila_canal_fora','falhou_no_envio','sem_telefone',
                         'pre_go_live','canal_arquivado','fora_da_janela')),

  criado_em        timestamptz not null default now(),
  -- Quem assumiu. `reconhecido_por is null` COM `reconhecido_em` preenchido = a
  -- conversa foi devolvida ao automático (ninguém assumiu, mas o episódio
  -- fechou). Nunca o contrário — é o que a constraint abaixo garante.
  reconhecido_por  uuid references auth.users(id) on delete set null,
  reconhecido_em   timestamptz,
  constraint passagens_reconhecimento_coerente
    check (reconhecido_por is null or reconhecido_em is not null)
);

-- Auto-cura para o clone que já tenha uma versão ANTERIOR da tabela: o
-- `create table if not exists` acima é no-op ali. Só as colunas que podem ser
-- acrescentadas a uma tabela COM LINHAS entram — as `not null` sem default não
-- podem, e não precisam: a tabela nasce aqui.
alter table public.passagens_de_atendimento add column if not exists caso_id uuid;
alter table public.passagens_de_atendimento add column if not exists title text;
alter table public.passagens_de_atendimento add column if not exists notes text;
alter table public.passagens_de_atendimento add column if not exists content text;
alter table public.passagens_de_atendimento add column if not exists tentativas jsonb not null default '[]'::jsonb;
alter table public.passagens_de_atendimento add column if not exists cliente_avisado boolean;
alter table public.passagens_de_atendimento add column if not exists aviso_motivo_codigo text;
alter table public.passagens_de_atendimento add column if not exists reconhecido_por uuid;
alter table public.passagens_de_atendimento add column if not exists reconhecido_em timestamptz;

-- Os CHECK em bloco próprio, para o clone que tenha a tabela sem eles.
-- `drop` + `add` é auto-curativo E é o que garante UMA constraint por coluna: o
-- nome usado aqui é o mesmo que o Postgres dá ao CHECK inline do `create table`
-- acima, então a segunda aplicação substitui em vez de duplicar. Duas
-- constraints definindo o mesmo vocabulário fazem
-- `tests/invariants/vocabulario-banco-x-typescript.test.ts` se RECUSAR a medir —
-- e ele está certo em se recusar: escolher uma daria veredito falso sobre todos
-- os pares.
alter table public.passagens_de_atendimento
  drop constraint if exists passagens_de_atendimento_motor_check;
alter table public.passagens_de_atendimento
  add constraint passagens_de_atendimento_motor_check
  check (motor in ('engine','crm'));

alter table public.passagens_de_atendimento
  drop constraint if exists passagens_de_atendimento_origem_check;
alter table public.passagens_de_atendimento
  add constraint passagens_de_atendimento_origem_check
  check (origem in (
    'pedido_explicito','opt_out_provavel','ferramenta_do_modelo',
    'teto_de_gasto','caso_escalado','sentimento','legado_pedido',
    'legado_juridico','legado_etapa','legado_confianca','legado_teto',
    'mcp_externo','runtime_nativo'));

alter table public.passagens_de_atendimento
  drop constraint if exists passagens_de_atendimento_motivo_codigo_check;
alter table public.passagens_de_atendimento
  add constraint passagens_de_atendimento_motivo_codigo_check
  check (motivo_codigo in (
    'requested_human','suspected_optout','orcamento_de_ia','low_sentiment',
    'low_confidence','critical_stage','legal_mention','refund_mention',
    'caso_escalado'));

alter table public.passagens_de_atendimento
  drop constraint if exists passagens_de_atendimento_aviso_motivo_codigo_check;
alter table public.passagens_de_atendimento
  add constraint passagens_de_atendimento_aviso_motivo_codigo_check
  check (aviso_motivo_codigo is null or aviso_motivo_codigo in (
    'na_fila_canal_fora','falhou_no_envio','sem_telefone',
    'pre_go_live','canal_arquivado','fora_da_janela'));

alter table public.passagens_de_atendimento
  drop constraint if exists passagens_de_atendimento_tentativas_check;
alter table public.passagens_de_atendimento
  add constraint passagens_de_atendimento_tentativas_check
  check (jsonb_typeof(tentativas) = 'array');

alter table public.passagens_de_atendimento
  drop constraint if exists passagens_reconhecimento_coerente;
alter table public.passagens_de_atendimento
  add constraint passagens_reconhecimento_coerente
  check (reconhecido_por is null or reconhecido_em is not null);

-- Três índices, um LEITOR DECLARADO cada. Índice sem leitor é evento sem
-- consumidor com outro nome.
--   · por conversa  → o cartão, que lista as passagens daquela conversa;
create index if not exists passagens_por_conversa
  on public.passagens_de_atendimento (organization_id, conversation_id, criado_em desc);
--   · por contato   → a redação e o export do titular (FK direta);
create index if not exists passagens_por_contato
  on public.passagens_de_atendimento (organization_id, contact_id, criado_em desc);
--   · não reconhecidas → o segundo braço do cobrador em
--     `app/api/v1/cron/case-stale-watcher` (onda seguinte) e o expurgo, que só
--     apaga linha JÁ reconhecida.
create index if not exists passagens_nao_reconhecidas
  on public.passagens_de_atendimento (organization_id, criado_em desc)
  where reconhecido_em is null;

alter table public.passagens_de_atendimento enable row level security;

-- ── Privilégio: leitura pelo login, escrita SÓ pelo servidor ───────────────
-- `revoke all` PRIMEIRO porque o `ALTER DEFAULT PRIVILEGES … GRANT ALL ON
-- TABLES TO "authenticated"` do baseline vem ANTES de toda tabela de apêndice:
-- sem o revoke, a tabela nasce com INSERT/UPDATE/DELETE para `authenticated` e a
-- policy seria a única coisa entre um `viewer` e a escrita. É exatamente o
-- defeito que a 0279 teve de consertar em três tabelas já nascidas.
--
-- E não há caminho de escrita pelo PostgREST NENHUM: quem grava é o service role
-- (os dois motores) e, na onda seguinte, o trigger definer do reconhecimento.
-- Uma passagem forjada por um membro é uma mentira com cara de registro — ela
-- diria que a IA desistiu de um atendimento que ela nunca tocou.
revoke all    on public.passagens_de_atendimento from anon, authenticated;
grant  select on public.passagens_de_atendimento to authenticated;
grant  all    on public.passagens_de_atendimento to service_role;

-- ── RLS: organização + papel + VISIBILIDADE DA CONVERSA ───────────────────
-- As três condições, e cada uma fecha uma porta diferente:
--   · `fn_user_org_ids`      — o vizinho não lê;
--   · `fn_role_at_least`     — `viewer` não lê briefing de atendimento (ele vê a
--     conversa por desenho, e o briefing diz MAIS que a conversa: diz o que a IA
--     concluiu sobre a pessoa);
--   · `fn_can_view_conversation` — numa organização em `visibility_mode='own'`,
--     um atendente não lê o briefing de um atendimento que não é dele. É o mesmo
--     predicado de `ai_reply_drafts`, e é a razão de `conversation_id` viver
--     dentro desta tabela.
drop policy if exists tenant_isolation_passagens_de_atendimento_all on public.passagens_de_atendimento;
drop policy if exists tenant_isolation_passagens_de_atendimento_select on public.passagens_de_atendimento;
create policy tenant_isolation_passagens_de_atendimento_select
  on public.passagens_de_atendimento
  for select to authenticated
  using (
    organization_id in (select public.fn_user_org_ids())
    and public.fn_role_at_least(organization_id, 'agent')
    and exists (
      select 1
        from public.conversations c
       where c.organization_id = passagens_de_atendimento.organization_id
         and c.id = passagens_de_atendimento.conversation_id
         and public.fn_can_view_conversation(c.organization_id, c.assigned_to_user_id)
    )
  );

-- ── Retenção: a tabela nasce com dono de piso ─────────────────────────────
create or replace function public.fn_expurgar_passagens_vencidas(
  p_retencao_dias int default null,
  p_limite int default null
) returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- 1825 = os 5 anos da auditoria, e pelo mesmo motivo: a passagem é rastro de
  -- ATENDIMENTO — quem assumiu, quando, e por quê. O piso de 90 impede que o
  -- knob vire apagador de rastro recente, e mora AQUI, no corpo, porque só assim
  -- vale para QUALQUER chamador, inclusive um `psql` na mão.
  v_dias int := greatest(coalesce(p_retencao_dias, 1825), 90);
  v_limite int := least(greatest(coalesce(p_limite, 1000), 1), 10000);
  v_apagadas int;
begin
  with vencidas as (
    select p.id from public.passagens_de_atendimento p
      -- ⚠️ SÓ passagem JÁ RECONHECIDA. Uma passagem aberta é demanda viva: alguém
      -- do outro lado está esperando resposta e ninguém assumiu. Apagá-la por
      -- idade seria o expurgo virando esquecedor de pendência — e o único sinal
      -- de que a pessoa ficou sem resposta some junto.
     where p.reconhecido_em is not null
       and p.criado_em < now() - make_interval(days => v_dias)
     order by p.criado_em
     limit v_limite
  )
  delete from public.passagens_de_atendimento p using vencidas v where p.id = v.id;
  get diagnostics v_apagadas = row_count;
  return v_apagadas;
end;
$$;
-- As DUAS origens de EXECUTE: o `ALTER DEFAULT PRIVILEGES … GRANT ALL ON
-- FUNCTIONS TO anon` do baseline (que `revoke from public` não remove) e o grant
-- implícito a PUBLIC que o Postgres dá a toda função ao criá-la (que `revoke
-- from anon` não remove). Fechar uma só deixa a função exposta com o gate verde.
revoke all     on function public.fn_expurgar_passagens_vencidas(int,int) from public, anon, authenticated;
grant  execute on function public.fn_expurgar_passagens_vencidas(int,int) to service_role;

-- ── A cascata de LGPD alcança a passagem ──────────────────────────────────
-- Derivada do corpo VIGENTE do baseline (a definição de maior número de linha),
-- por script, nunca redigitada: o corpo anterior fica byte a byte igual e as
-- ÚNICAS mudanças são as duas declaradas — o passo de `passagens_de_atendimento`
-- e o `last_handoff_reason = null` dentro do passo 2, que já visita as mesmas
-- linhas com o mesmo predicado. O Postgres troca o corpo INTEIRO num `create or
-- replace`; quem derivar da versão errada apaga o passo de outra entrega sem um
-- único erro. A catraca que vigia isso é
-- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
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
  perform public.fn_service_lock(p_organization_id,p_contact_id);
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
    -- O motivo CRU da última passagem (migration 0291). É código de
    -- vocabulário, não texto livre — mas ele diz que ESTA pessoa foi escalada
    -- por irritação, por assunto jurídico ou por suspeita de opt-out, e isso é
    -- um fato sobre ela. Entra NESTE update, e não num segundo: mesmo
    -- predicado, mesmas linhas, metade das varreduras.
    --
    -- ⚠️ `last_handoff_reason` é CHAVE DE NEGÓCIO em outro módulo: a ponte de
    -- voz limpa o silêncio filtrando pelo VALOR da coluna
    -- (`lib/wacalls/events-bridge.ts`). Zerá-la num contato anonimizado é
    -- seguro — não há chamada viva de contato anonimizado — e é a razão de
    -- esta entrega NÃO usar essa coluna para texto rico: ela continua
    -- recebendo só o código, e o texto vive em `passagens_de_atendimento`.
    last_handoff_reason = null,
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

  -- 7b. voice_calls — o TELEFONE de quem falou ao telefone (migration 0235).
  --
  -- `peer_phone` é `not null` e guarda o número da outra ponta: depois de
  -- anonimizar o contato, ele sobrevivia ligado ao `contact_id` e reidentificava
  -- a pessoa que pediu para ser esquecida. É o mesmo argumento que a foto de
  -- perfil já tinha (ver o bloco do avatar em `lib/lgpd/redact-cascade.ts`):
  -- anonimizar em toda parte menos numa é não ter anonimizado.
  --
  -- O que fica: direção, status, motivo do fim, marcas de tempo e duração. Um
  -- registro de "houve uma chamada de 12 minutos" sem número e sem dono não
  -- identifica ninguém e é o que sustenta a métrica do atendente e a fatura.
  -- `peer_phone` é NOT NULL, então recebe o rótulo, não `null`.
  update voice_calls set
    peer_phone = v_anon_label,
    owner_user_id = null,
    created_by = null,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('voice_calls', v_count);

  -- agent_cases — o que a IA escreveu SOBRE a pessoa quando travou (migration 0280).
  --
  -- O caso é o texto que a equipe lê antes de decidir: `title`, `summary` e
  -- `blocker` saem do modelo a partir da conversa, e `context_snapshot` é o
  -- recorte dessa conversa que o motor mandou para ele. Nada disso é registro de
  -- operação — é o relato do problema de uma pessoa identificável, escrito por
  -- máquina. Sem este passo, anonimizar devolvia SUCESSO com o relato intacto.
  --
  -- As três colunas de texto são `not null`: recebem rótulo e texto fixo, nunca
  -- `null` (a mesma razão de `voice_calls.peer_phone` logo acima).
  --
  -- ⚠️ `updated_at` FICA FORA DO `set`, de propósito. O cobrador de caso parado
  -- (`app/api/v1/cron/case-stale-watcher/route.ts`) lê `updated_at` como "alguém
  -- da equipe encostou neste caso". A cascata não é alguém encostando: escrever
  -- ali faria a anonimização ADIAR a cobrança de um caso que continua parado, e
  -- o efeito só apareceria como um cliente esperando mais tempo.
  --
  -- O vínculo é pela CONVERSA porque `agent_cases` não tem FK para `contacts`.
  update agent_cases set
    title = v_anon_label,
    summary = '[resumo anonimizado]',
    blocker = '[bloqueio anonimizado]',
    context_snapshot = '{}'::jsonb
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_cases', v_count);

  -- agent_case_events — a linha do tempo do caso (migration 0280).
  --
  -- `body` é o que a pessoa da equipe escreveu ao responder o caso e o que o
  -- agente registrou sobre o que o LEAD respondeu; `metadata` carrega o recorte
  -- que o motor anexou. `kind`, `actor_kind`, `human_action` e `created_at`
  -- FICAM: são o registro de que houve um toque humano e quando — operação, não
  -- dado da pessoa, e é deles que sai a métrica de atendimento.
  update agent_case_events set
    body = null,
    metadata = '{}'::jsonb
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_events', v_count);

  -- demandas — o assunto do pedido (migration 0280).
  --
  -- `assunto` é texto livre sobre o que a pessoa pediu. O resto da linha é a
  -- operação da demanda (origem, estado, dono, prazo, desfecho) e fica de pé:
  -- apagar a linha inteira tiraria da organização a resposta a "quantos pedidos
  -- houve em março", que é o mesmo argumento do compromisso da agenda.
  --
  -- FK direta (`demandas.contact_id` é `not null`), então o vínculo é o contato.
  update demandas set
    assunto = null
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('demandas', v_count);

  -- agent_inbox_items — o aviso que leva o texto do caso para a Central (migration 0280).
  --
  -- O `body` do aviso de caso parado EMBUTE o título do caso
  -- (`app/api/v1/cron/case-stale-watcher/route.ts:128`), e o do handoff embute o
  -- motivo da parada (`lib/ai/handoff/orchestrator.ts:335`). Redigir o caso e
  -- deixar o aviso de pé seria anonimizar em toda parte menos numa — que é não
  -- ter anonimizado. O molde (resolver + trocar o corpo + soltar a referência) é
  -- o de `fn_meet_redact_contact`, que já faz isto para o aviso de compromisso.
  --
  -- ⚠️ O VÍNCULO É POLIMÓRFICO E TEM TRÊS BRAÇOS, não dois. Medido nos
  -- produtores, não suposto: `handoff` nasce com `ref_kind='contact'`
  -- (`lib/ai/handoff/orchestrator.ts:339`) E com `ref_kind='conversation'`
  -- (`lib/agent-engine/agent/inbound-turn.ts:4100`); `case_stale` nasce SEMPRE
  -- com `ref_kind='agent_case'` (a rota do cron acima, e a política em
  -- `lib/ai/inbox-destino.ts:38`). Um predicado com só os dois primeiros braços
  -- casa ZERO avisos de caso parado — e casar zero linha não é erro: é sucesso
  -- com o texto intacto.
  --
  -- Os `kind` são os MEDIDOS no CHECK vigente (`supabase/baseline.sql`, bloco
  -- único de `agent_inbox_items_kind_check`). `case_opened` NÃO existe, e kind
  -- inexistente num `in (...)` também casa zero e devolve sucesso. Para
  -- reconferir sem acreditar nesta prosa:
  --   grep -n "agent_inbox_items_kind_check check" -A40 supabase/baseline.sql
  update agent_inbox_items set
    status = 'resolved',
    resolved_at = now(),
    body = 'Contato anonimizado.',
    ref_id = null
  where organization_id = p_organization_id
    and kind in ('handoff', 'case_stale')
    and (
      (ref_kind = 'contact' and ref_id = p_contact_id)
      or (ref_kind = 'conversation' and ref_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          ))
      or (ref_kind = 'agent_case' and ref_id in (
            select id from agent_cases
              where organization_id = p_organization_id
                and conversation_id in (
                  select id from conversations
                    where contact_id = p_contact_id and organization_id = p_organization_id
                )
          ))
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_inbox_items', v_count);

  -- agent_case_chat_messages — a consulta interna da equipe à IA SOBRE o caso
  -- (migration 0281). FK DIRETA para `contacts`, então o vínculo é o titular e
  -- não precisa passar pela conversa.
  --
  -- `redacted_at is null` no `where` é o que torna o passo IDEMPOTENTE: a
  -- varredura diária de redações incompletas roda a função de novo, e sem essa
  -- condição o carimbo de QUANDO se apagou seria reescrito a cada rodada.
  --
  -- A linha NÃO é apagada, só o texto: quem abrir o caso depois continua vendo
  -- que a equipe perguntou N vezes, quando, e se a IA respondeu. Apagar a linha
  -- inteira ficaria verde num teste de "o texto sumiu" e tiraria da organização
  -- a resposta a "quanto a equipe deliberou sobre este caso".
  update agent_case_chat_messages set
    body = null,
    redacted_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id
    and redacted_at is null;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_chat_messages', v_count);

  -- passagens_de_atendimento — o BRIEFING é sobre a pessoa (migration 0291).
  --
  -- A linha guarda o que a IA concluiu sobre um atendimento de alguém
  -- identificável: o que ela entendeu que a pessoa quer (`title`), a narrativa
  -- que quem assumiu leu (`body`), as PALAVRAS LITERAIS do cliente (`notes`), o
  -- texto livre de quem passou (`content`) e o que a IA já tinha tentado
  -- (`tentativas`). Nada disso é registro de operação — é o relato do problema
  -- de uma pessoa, escrito por máquina, na tela de quem vai responder.
  --
  -- `body` é `not null` e recebe o RÓTULO, não `null` — a mesma razão de
  -- `voice_calls.peer_phone` e de `agent_cases.title` acima: coluna obrigatória
  -- anulada aborta o cascade INTEIRO, e um cascade abortado não anonimiza nada.
  --
  -- O que FICA, de propósito: `motor`, `origem`, `motivo_codigo`,
  -- `cliente_avisado`, `aviso_motivo_codigo`, `criado_em` e o par de
  -- reconhecimento. São operação — quantas passagens houve, por quê, quanto
  -- tempo até alguém assumir. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos atendimentos a IA devolveu em março, e quanto tempo esperaram".
  --
  -- O vínculo é a FK DIRETA `contact_id`: a tabela a carrega exatamente para
  -- este passo não precisar passar pela conversa.
  update passagens_de_atendimento set
    body       = v_anon_label,
    title      = null,
    notes      = null,
    content    = null,
    tentativas = '[]'::jsonb
  where organization_id = p_organization_id and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('passagens_de_atendimento', v_count);

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

-- ── travas do suporte, depois de toda tabela nova (migration 0274) ─────────
-- `passagens_de_atendimento` nasce SERVER-ONLY (revoke de anon/authenticated +
-- grant select), então o ramo server-only da função lhe dá ZERO policies
-- `support_write_*` — que é o contrato mais restritivo. Escrever `drop policy` à
-- mão aqui seria a segunda representação da mesma regra.
do $f$ begin perform public.fn_aplicar_travas_de_suporte(); end $f$;

notify pgrst, 'reload schema';


-- ---- o WhatsApp da equipe é avisado quando a IA abre um caso (migration 0292) ----
-- 0292 — O WhatsApp da equipe é avisado quando a IA abre um caso.
--
-- ─── O que não existia ────────────────────────────────────────────────────
--
-- A IA abre um caso quando trava (`agent_cases`), o caso entra numa fila e
-- espera alguém da equipe. O único lugar onde ele APARECE é uma tela do CRM —
-- e quem opera uma PME não fica com o CRM aberto: fica com o WhatsApp aberto.
-- O cobrador de caso parado (`app/api/v1/cron/case-stale-watcher`) só reclama
-- DEPOIS de horas, e reclama na mesma tela que ninguém abriu. O resultado
-- medido é um cliente esperando do outro lado sem que ninguém tenha sido
-- avisado de nada.
--
-- Esta migration é o SCHEMA e as RPCs desse aviso. A tela que o liga é a onda
-- seguinte; o motor que o envia (`lib/escalacao/aviso-ao-suporte.ts`) entra no
-- MESMO commit que este arquivo.
--
-- ─── DOUTRINA DIRC, respondida ────────────────────────────────────────────
--
--   Duplicar   — não: não existe hoje nenhuma tabela de "para onde mandar
--                aviso interno" (`organizations.settings` guarda preferência de
--                produto, não vínculo com `channel_sessions`);
--   Integrar   — `channel_session_id` e `case_id` são FK, não cópias;
--   Referenciar— `status` e `erro_codigo` são vocabulário fechado;
--   Calcular   — "este aviso já saiu?" NÃO é calculável depois: sem a linha de
--                entrega, o único jeito de saber seria reler o WhatsApp da
--                equipe, e a segunda rodada do dreno mandaria de novo.
--
-- ─── AS DUAS TABELAS, e por que são duas ──────────────────────────────────
--
--   `config_aviso_de_caso`    — UMA linha por organização: para onde mandar,
--                               por qual conexão, ligado ou não.
--   `entregas_de_aviso_de_caso` — UMA linha por (organização, caso, destino).
--                               É a `unique` dela que dá a IDEMPOTÊNCIA: o
--                               dreno do `event_log` reentrega o mesmo evento
--                               em retry, e sem essa chave a equipe receberia o
--                               mesmo aviso três vezes.
--
-- **O TEXTO DO AVISO NUNCA É GUARDADO.** Só `corpo_hash` — precedente
-- `send_ledger.body_hash`. Um registro de entrega que guardasse o corpo seria
-- uma segunda cópia do relato do cliente, numa tabela que a cascata de LGPD
-- teria de aprender a redigir. A única coluna capaz de ecoar um dado pessoal é
-- `erro_detalhe` (o texto cru do transporte), e é ela que a cascata zera.
--
-- ─── POR QUE NÃO HÁ `check (ligado = false or channel_session_id is not null)`
--
-- Ele parece a expressão natural de "ligado sem canal nunca dispara", e é uma
-- armadilha: `on delete set null` é um UPDATE, o CHECK é reavaliado na linha
-- resultante e VIOLA quando `ligado` é `true` — abortando o DELETE INTEIRO da
-- conexão. A rota de exclusão de canal devolveria 500 com mensagem de
-- constraint, sem nenhuma pista de que a causa está em outra tela. A coerência
-- é do trigger `trg_aviso_de_caso_coerente`, que se autocura: canal nulo ⇒
-- `ligado` cai para `false`, e a tela explica o que houve.
--
-- ─── POR QUE A ESCRITA É POR RPC E A LEITURA É POR RLS ────────────────────
--
-- Padrão vigente da 0228 e da 0262. A escrita precisa de quatro guardas na
-- MESMA transação (papel `admin`, escrita de suporte liberada, MFA comprovada
-- quando há fator, e o canal sendo da própria organização) — e uma policy não
-- sabe recusar "este número já é de um cliente seu". A leitura da CONFIGURAÇÃO
-- é `admin` (quem configura conexão é admin); a do HISTÓRICO é `manager`,
-- porque "o aviso está saindo?" é pergunta de quem opera o atendimento.
-- Nenhuma policy `for all` ⇒ as duas tabelas nascem fora da consulta `cmd='ALL'`
-- do gate de RBAC, sem entrar em dívida nova.
--
-- ─── AS DUAS COLUNAS DE CONTAGEM NÃO SÃO ENFEITE ──────────────────────────
--
-- `mensagens_ignoradas` / `ultima_mensagem_ignorada_em` existem porque a onda
-- do corte (o número de aviso é INTERNO: nada que venha dele vira contato,
-- conversa, lead ou despacho do agente) produz um silêncio que, na tela, é
-- indistinguível de defeito. Com elas a tela diz "3 mensagens deste número
-- foram ignoradas nos últimos 7 dias — é o esperado". Quem incrementa é
-- `fn_contar_mensagem_ignorada`, e ela NÃO toca `updated_at`: aquele carimbo
-- responde "quando alguém mexeu na configuração", e uma resposta do suporte não
-- é alguém mexendo na configuração.
--
-- ─── REAPLICAÇÃO ──────────────────────────────────────────────────────────
--
-- `create table if not exists`, `add column if not exists`, `drop constraint if
-- exists` + `add constraint`, `create index if not exists`, `drop policy if
-- exists` + `create policy`, `create or replace function`, `drop trigger if
-- exists` + `create trigger`. O `update.sh` de um clone reaplica sem erro e sem
-- duplicar efeito. Nenhuma constraint nova sobre dados existentes (as duas
-- tabelas nascem aqui, e os dois CHECK de vocabulário só CRESCEM) ⇒ não há
-- deduplicação prévia a fazer (regra 8 da doutrina de migrations).

create table if not exists public.config_aviso_de_caso (
  organization_id     uuid primary key references public.organizations(id) on delete cascade,
  -- NULLABLE de propósito, e `set null` e não `cascade`/`restrict`: com
  -- `cascade` a exclusão do canal apagaria a configuração CALADA; com
  -- `restrict`, a exclusão do canal falharia por causa de um aviso. `set null`
  -- desliga (pelo trigger) e deixa a tela explicar.
  channel_session_id  uuid references public.channel_sessions(id) on delete set null,
  -- E.164, com `+`. É o que a pessoa digita e o que o transporte recebe.
  telefone_destino    text not null,
  -- O JID que o transporte resolveu da última vez. É o que faz o corte da
  -- ingestão funcionar para destinatário em MODO PRIVACIDADE, onde o telefone
  -- nunca chega no webhook e o chat chega como um identificador opaco.
  destino_jid         text,
  -- Como a equipe chama esse número ("Plantão", "Suporte 1"). Só rótulo.
  rotulo              text,
  ligado              boolean not null default false,
  -- A SUPERFÍCIE DO DESCARTE (ver o cabeçalho): sem elas, "as mensagens deste
  -- número somem" é indistinguível de defeito para quem olha a tela.
  mensagens_ignoradas         integer not null default 0,
  ultima_mensagem_ignorada_em timestamptz,
  criado_por          uuid references auth.users(id) on delete set null,
  atualizado_por      uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  -- Responde "quando alguém MEXEU na configuração" — e só isso. O contador de
  -- mensagens ignoradas não o toca de propósito.
  updated_at          timestamptz not null default now()
);

-- Colunas declaradas de novo para o clone que já tenha a tabela de uma versão
-- anterior deste arquivo: `add column if not exists` é o que torna o apêndice
-- auto-curativo.
alter table public.config_aviso_de_caso
  add column if not exists destino_jid                 text,
  add column if not exists rotulo                      text,
  add column if not exists mensagens_ignoradas         integer not null default 0,
  add column if not exists ultima_mensagem_ignorada_em timestamptz,
  add column if not exists criado_por                  uuid,
  add column if not exists atualizado_por              uuid;

-- As constraints nomeadas fora do `create table`: é o que as torna
-- auto-curativas num clone cuja tabela nasceu de uma versão anterior. O nome é
-- o MESMO que o Postgres daria ao inline, então não há duas constraints
-- definindo o mesmo domínio — duas fariam o invariante de vocabulário se
-- RECUSAR a medir.
alter table public.config_aviso_de_caso
  drop constraint if exists config_aviso_de_caso_e164;
alter table public.config_aviso_de_caso
  add constraint config_aviso_de_caso_e164
  check (telefone_destino ~ '^\+[1-9][0-9]{7,14}$');

alter table public.config_aviso_de_caso
  drop constraint if exists config_aviso_de_caso_rotulo_curto;
alter table public.config_aviso_de_caso
  add constraint config_aviso_de_caso_rotulo_curto
  check (rotulo is null or char_length(rotulo) <= 60);

-- Coerência que se AUTOCURA, em vez de um CHECK que aborta o DELETE da conexão
-- (ver o cabeçalho). `before insert or update` para valer também quando o
-- `on delete set null` da FK dispara o UPDATE.
create or replace function public.fn_aviso_de_caso_coerente()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Sem canal não há por onde mandar. Deixar `ligado = true` aqui produziria a
  -- pior tela possível: a que diz que o aviso está ativo enquanto ele nunca
  -- dispara. `security invoker` de propósito — ela não lê nem escreve nada além
  -- da linha que o próprio comando já está tocando.
  if new.channel_session_id is null then
    new.ligado := false;
  end if;
  return new;
end;
$$;
revoke all on function public.fn_aviso_de_caso_coerente() from public, anon, authenticated;

drop trigger if exists trg_aviso_de_caso_coerente on public.config_aviso_de_caso;
create trigger trg_aviso_de_caso_coerente
  before insert or update on public.config_aviso_de_caso
  for each row execute function public.fn_aviso_de_caso_coerente();

create table if not exists public.entregas_de_aviso_de_caso (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations(id) on delete cascade,
  case_id             uuid not null references public.agent_cases(id)   on delete cascade,
  -- O destino NO INSTANTE do envio. Não é FK para a configuração de propósito:
  -- trocar o número do plantão não pode reescrever para onde os avisos de ontem
  -- foram — isso é registro, não estado.
  destino             text not null,
  channel_session_id  uuid references public.channel_sessions(id) on delete set null,
  status              text not null default 'pendente',
  tentativas          smallint not null default 0,
  -- Vocabulário FECHADO (lib/escalacao/vocabulario-do-aviso.ts), nunca a
  -- mensagem do provedor: é o que a tela lê e o que a Central traduz.
  erro_codigo         text,
  -- O texto cru do transporte, truncado. ÚNICA coluna desta tabela capaz de
  -- ecoar um dado pessoal — e é por isso que a cascata de LGPD a zera.
  erro_detalhe        text,
  external_id         text,
  -- O TEXTO NUNCA É GUARDADO (precedente: `send_ledger.body_hash`). O hash
  -- responde "o aviso que saiu era este?" sem guardar o relato do cliente uma
  -- segunda vez.
  corpo_hash          text,
  enviado_em          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table public.entregas_de_aviso_de_caso
  add column if not exists channel_session_id uuid,
  add column if not exists erro_codigo        text,
  add column if not exists erro_detalhe       text,
  add column if not exists external_id        text,
  add column if not exists corpo_hash         text,
  add column if not exists enviado_em         timestamptz;

alter table public.entregas_de_aviso_de_caso
  drop constraint if exists entregas_de_aviso_de_caso_status_check;
alter table public.entregas_de_aviso_de_caso
  add constraint entregas_de_aviso_de_caso_status_check
  check (status in ('pendente', 'enviado', 'falhou', 'cancelado'));

alter table public.entregas_de_aviso_de_caso
  drop constraint if exists entregas_de_aviso_de_caso_erro_codigo_check;
alter table public.entregas_de_aviso_de_caso
  add constraint entregas_de_aviso_de_caso_erro_codigo_check
  check (erro_codigo is null or erro_codigo in (
    'canal_desconectado',
    'canal_arquivado',
    'canal_nao_aceita_aviso_livre',
    'transporte_ausente',
    'destino_invalido',
    'teto_diario_do_numero',
    'sem_endereco_publico',
    'titular_anonimizado',
    'expirou',
    'falha_no_envio',
    'indeterminado'));

-- A CHAVE DA IDEMPOTÊNCIA. O dreno do `event_log` reentrega o mesmo evento em
-- retry e três processos diferentes drenam a mesma fila: sem esta unique, a
-- equipe receberia o mesmo aviso uma vez por tentativa. O `23505` dela é o
-- sinal que o handler lê para REIVINDICAR a entrega antes de tocar a rede.
create unique index if not exists entregas_de_aviso_de_caso_unica
  on public.entregas_de_aviso_de_caso (organization_id, case_id, destino);

-- O leitor declarado: a lista "os últimos avisos" da tela de configuração, que
-- é a fonte da verdade sobre "o aviso está saindo?" (a Central pode ter tido o
-- item apagado por qualquer membro; esta tabela, não).
create index if not exists entregas_de_aviso_de_caso_org_idx
  on public.entregas_de_aviso_de_caso (organization_id, created_at desc);

-- `updated_at` da ENTREGA é operacional: ele responde "há quanto tempo esta
-- reivindicação está de pé?", e é ele que separa "outro processo está enviando
-- agora" de "alguém morreu no meio". Por isso a entrega ganha o trigger e a
-- CONFIGURAÇÃO não: lá o carimbo significa "alguém mexeu", e um contador de
-- mensagem ignorada não é alguém mexendo.
drop trigger if exists trg_entregas_de_aviso_de_caso_updated_at on public.entregas_de_aviso_de_caso;
create trigger trg_entregas_de_aviso_de_caso_updated_at
  before update on public.entregas_de_aviso_de_caso
  for each row execute function public.fn_set_updated_at();

alter table public.config_aviso_de_caso      enable row level security;
alter table public.entregas_de_aviso_de_caso enable row level security;

-- `revoke all` PRIMEIRO: o `ALTER DEFAULT PRIVILEGES … GRANT ALL ON TABLES TO
-- "authenticated"` do baseline vem ANTES de toda tabela de apêndice, então sem
-- ele as tabelas nascem com INSERT/UPDATE/DELETE para `authenticated` e a
-- policy seria a única coisa entre um `viewer` e a escrita. É o defeito que a
-- 0279 teve de consertar em três tabelas já nascidas.
revoke all    on public.config_aviso_de_caso      from anon, authenticated;
revoke all    on public.entregas_de_aviso_de_caso from anon, authenticated;
grant  select on public.config_aviso_de_caso      to authenticated;
grant  select on public.entregas_de_aviso_de_caso to authenticated;
grant  all    on public.config_aviso_de_caso      to service_role;
grant  all    on public.entregas_de_aviso_de_caso to service_role;

-- Leitura da CONFIGURAÇÃO: `admin`. Ela carrega o telefone de um funcionário e
-- o vínculo com a conexão — quem configura conexão neste produto é admin.
drop policy if exists leitura_config_aviso_de_caso on public.config_aviso_de_caso;
create policy leitura_config_aviso_de_caso
  on public.config_aviso_de_caso
  for select to authenticated
  using (
    organization_id in (select public.fn_user_org_ids())
    and public.fn_role_at_least(organization_id, 'admin')
  );

-- Leitura do HISTÓRICO: `manager`. "O aviso está saindo?" é pergunta de quem
-- opera o atendimento, e a linha não expõe o número inteiro para a tela (que o
-- mascara) nem guarda texto nenhum.
drop policy if exists leitura_entregas_de_aviso_de_caso on public.entregas_de_aviso_de_caso;
create policy leitura_entregas_de_aviso_de_caso
  on public.entregas_de_aviso_de_caso
  for select to authenticated
  using (
    organization_id in (select public.fn_user_org_ids())
    and public.fn_role_at_least(organization_id, 'manager')
  );

-- ── A escrita da configuração: uma RPC, quatro guardas, uma transação ──────
create or replace function public.fn_definir_aviso_de_caso(
  p_org uuid,
  p_channel uuid,
  p_telefone text,
  p_rotulo text,
  p_ligado boolean,
  p_confirma_contato boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_antes public.config_aviso_de_caso;
  v_arch timestamptz;
  v_digitos text;
  v_variantes text[];
begin
  -- Papel + suporte, nesta ordem e na MESMA transação da escrita. `auth.uid()`
  -- nulo é o caminho do service role: quem escreve configuração é gente.
  if auth.uid() is null or p_org is null
     or not public.fn_role_at_least(p_org, 'admin')
     or not public.fn_support_write_allowed(p_org) then
    raise exception 'aviso_de_caso_forbidden' using errcode = '42501';
  end if;
  -- Quem NÃO tem fator cadastrado passa: a função já trata isso, e é coerente
  -- com a política de MFA opcional deste produto.
  if not public.fn_session_mfa_proven() then
    raise exception 'aviso_de_caso_mfa_required' using errcode = '42501';
  end if;
  if p_telefone is null or p_telefone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'aviso_de_caso_telefone_invalido' using errcode = '22023';
  end if;

  -- O canal é DA organização e não está arquivado. Sem isto a FK simples
  -- deixaria apontar para o canal de outro tenant — a FK composta do padrão
  -- 0228 não serve aqui porque o `on delete set null` anularia também
  -- `organization_id`, que é a chave primária desta tabela.
  if p_channel is not null then
    select archived_at into v_arch
      from public.channel_sessions
     where id = p_channel and organization_id = p_org;
    if not found or v_arch is not null then
      raise exception 'aviso_de_caso_canal_invalido' using errcode = '22023';
    end if;
  end if;

  -- As duas grafias do nono dígito — a MESMA regra de
  -- `lib/channels/phone-variants.ts`. Comparar a string crua deixaria passar o
  -- número do suporte cadastrado com 9 e registrado sem.
  v_digitos := regexp_replace(p_telefone, '\D', '', 'g');
  v_variantes := array[v_digitos];
  if v_digitos like '55%' then
    if length(v_digitos) = 13
       and substring(v_digitos from 5 for 1) = '9'
       and substring(v_digitos from 6 for 1) between '6' and '9' then
      v_variantes := v_variantes || (substring(v_digitos from 1 for 4) || substring(v_digitos from 6));
    elsif length(v_digitos) = 12
       and substring(v_digitos from 5 for 1) between '6' and '9' then
      v_variantes := v_variantes || (substring(v_digitos from 1 for 4) || '9' || substring(v_digitos from 5));
    end if;
  end if;

  -- O NÚMERO DE AVISO NÃO PODE SER UM NÚMERO DA PRÓPRIA ORGANIZAÇÃO. É o laço
  -- robô-com-robô: a conexão de avisos manda para o número oficial, o agente
  -- dele responde, e as duas pontas se alimentam sem fim.
  if exists (
       select 1 from public.channel_sessions s
        where s.organization_id = p_org
          and s.phone_number is not null
          and regexp_replace(s.phone_number, '\D', '', 'g') = any (v_variantes)) then
    raise exception 'aviso_de_caso_numero_da_propria_org' using errcode = '22023';
  end if;

  -- O número de aviso vira INTERNO: tudo o que chegar dele deixa de virar
  -- contato, conversa, lead e despacho do agente. Se ele já é um CLIENTE desta
  -- organização, as mensagens dessa pessoa param de chegar ao CRM — e isso não
  -- pode acontecer por engano. A tela pergunta e reenvia com `p_confirma_contato`.
  if not coalesce(p_confirma_contato, false) and exists (
       select 1 from public.contacts c
        where c.organization_id = p_org
          and c.phone_number is not null
          and regexp_replace(c.phone_number, '\D', '', 'g') = any (v_variantes)) then
    raise exception 'aviso_de_caso_numero_de_cliente' using errcode = '22023';
  end if;

  select * into v_antes from public.config_aviso_de_caso where organization_id = p_org;

  insert into public.config_aviso_de_caso
    (organization_id, channel_session_id, telefone_destino, rotulo, ligado, criado_por, atualizado_por)
  values
    (p_org, p_channel, p_telefone, nullif(btrim(p_rotulo), ''), coalesce(p_ligado, false), auth.uid(), auth.uid())
  on conflict (organization_id) do update
    set channel_session_id = excluded.channel_session_id,
        telefone_destino   = excluded.telefone_destino,
        rotulo             = excluded.rotulo,
        ligado             = excluded.ligado,
        atualizado_por     = auth.uid(),
        -- Trocou o número, o JID resolvido do anterior não vale mais — e é o
        -- JID que o corte da ingestão usa para reconhecer quem está em modo
        -- privacidade. Mantê-lo faria o corte continuar valendo para o número
        -- ANTIGO, que pode voltar a ser um cliente.
        destino_jid        = case
                               when excluded.telefone_destino is distinct from config_aviso_de_caso.telefone_destino
                               then null
                               else config_aviso_de_caso.destino_jid
                             end,
        updated_at         = now();

  return jsonb_build_object(
    'trocou_numero', (v_antes.telefone_destino is distinct from p_telefone),
    'antes_ligado',  coalesce(v_antes.ligado, false)
  );
end;
$$;
-- AS DUAS ORIGENS DE EXECUTE (item 9 da doutrina de migrations): o grant direto
-- a `anon` do `ALTER DEFAULT PRIVILEGES … GRANT ALL ON FUNCTIONS TO anon` do
-- baseline (que `revoke from public` não remove) e o grant implícito a PUBLIC
-- que o Postgres dá a toda função ao criá-la (que `revoke from anon` não
-- remove). Fechar uma só deixa a função exposta com o gate verde.
revoke all     on function public.fn_definir_aviso_de_caso(uuid,uuid,text,text,boolean,boolean) from public, anon;
grant  execute on function public.fn_definir_aviso_de_caso(uuid,uuid,text,text,boolean,boolean) to authenticated;

-- ── O JID que o transporte resolveu ───────────────────────────────────────
-- Função SEPARADA, e não `update` direto pelo handler: dar `update` da
-- configuração ao service role abriria o caminho de "o motor mudou o número de
-- destino sozinho". Aqui ele só pode gravar UM campo, o que ele mesmo resolveu.
create or replace function public.fn_registrar_jid_do_aviso(p_org uuid, p_jid text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_org is null or p_jid is null or btrim(p_jid) = '' then
    return;
  end if;
  -- `is distinct from` para não gastar um UPDATE (e o trigger de coerência) a
  -- cada aviso enviado: o JID muda uma vez e depois é sempre o mesmo.
  -- `updated_at` FICA FORA: ele responde "alguém mexeu na configuração".
  update public.config_aviso_de_caso
     set destino_jid = p_jid
   where organization_id = p_org
     and destino_jid is distinct from p_jid;
end;
$$;
revoke all     on function public.fn_registrar_jid_do_aviso(uuid,text) from public, anon, authenticated;
grant  execute on function public.fn_registrar_jid_do_aviso(uuid,text) to service_role;

-- ── O contador do descarte ────────────────────────────────────────────────
-- Chamada pelos ingestores quando uma mensagem do número interno é descartada.
-- Sem ela o silêncio é indistinguível de defeito para quem olha a tela.
create or replace function public.fn_contar_mensagem_ignorada(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_org is null then
    return;
  end if;
  -- `updated_at` FICA FORA, de propósito: uma resposta do suporte não é alguém
  -- mexendo na configuração, e a tela usa aquele carimbo para dizer "alterado
  -- por Fulano em tal dia".
  update public.config_aviso_de_caso
     set mensagens_ignoradas = mensagens_ignoradas + 1,
         ultima_mensagem_ignorada_em = now()
   where organization_id = p_org;
end;
$$;
revoke all     on function public.fn_contar_mensagem_ignorada(uuid) from public, anon, authenticated;
grant  execute on function public.fn_contar_mensagem_ignorada(uuid) to service_role;

-- ── Retenção: a tabela nasce com dono de piso ─────────────────────────────
create or replace function public.fn_expurgar_avisos_de_caso_vencidos(
  p_retencao_dias int default null,
  p_limite int default null
) returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- 180 dias: mais curto que a auditoria (5 anos) porque a pergunta útil — "o
  -- aviso daquele caso saiu?" — é de semanas, não de anos. O piso de 30 impede
  -- que o knob vire apagador do rastro de um incidente que ainda está sendo
  -- apurado, e mora AQUI, no corpo, porque só assim vale para QUALQUER
  -- chamador, inclusive um `psql` na mão.
  v_dias int := greatest(coalesce(p_retencao_dias, 180), 30);
  v_limite int := least(greatest(coalesce(p_limite, 1000), 1), 10000);
  v_apagadas int;
begin
  with vencidas as (
    select e.id from public.entregas_de_aviso_de_caso e
     where e.created_at < now() - make_interval(days => v_dias)
     order by e.created_at
     limit v_limite
  )
  delete from public.entregas_de_aviso_de_caso e using vencidas v where e.id = v.id;
  get diagnostics v_apagadas = row_count;
  return v_apagadas;
end;
$$;
revoke all     on function public.fn_expurgar_avisos_de_caso_vencidos(int,int) from public, anon, authenticated;
grant  execute on function public.fn_expurgar_avisos_de_caso_vencidos(int,int) to service_role;

-- Os dois CHECK de vocabulário (`agent_case_events.kind` += 'alert_sent' e
-- `agent_inbox_items.kind` += 'aviso_de_caso_nao_entregue') NÃO são
-- reconstruídos aqui: neste arquivo cada constraint tem UM bloco só, e os
-- valores novos foram acrescentados ao bloco original (o de
-- `agent_case_events.kind ganha 'agent_noted' (migration 0100)` e o de
-- `agent_inbox_items.kind ganha 'capabilities_missing' (migration 0105)`).
-- Um segundo bloco é o defeito da issue #159: num banco com uma linha do
-- vocabulário mais novo, ele falha ao reaplicar e a tabela fica sem
-- constraint entre o `drop` e o `add` que funciona. Para conferir na fonte:
--   grep -c "agent_inbox_items_kind_check check" supabase/baseline.sql

-- ── A cascata de LGPD alcança o registro de entrega ───────────────────────
-- Derivada do corpo VIGENTE do baseline (a definição de maior número de linha),
-- por script, nunca redigitada: o corpo anterior fica byte a byte igual e as
-- ÚNICAS mudanças são as duas declaradas — o passo de `entregas_de_aviso_de_caso`
-- e o `aviso_de_caso_nao_entregue` acrescentado ao `kind in (...)` do passo de
-- `agent_inbox_items`. O Postgres troca o corpo INTEIRO num `create or replace`;
-- quem derivar da versão errada apaga o passo de outra entrega sem um único
-- erro. A catraca que vigia isso é
-- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
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
  perform public.fn_service_lock(p_organization_id,p_contact_id);
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
    -- O motivo CRU da última passagem (migration 0291). É código de
    -- vocabulário, não texto livre — mas ele diz que ESTA pessoa foi escalada
    -- por irritação, por assunto jurídico ou por suspeita de opt-out, e isso é
    -- um fato sobre ela. Entra NESTE update, e não num segundo: mesmo
    -- predicado, mesmas linhas, metade das varreduras.
    --
    -- ⚠️ `last_handoff_reason` é CHAVE DE NEGÓCIO em outro módulo: a ponte de
    -- voz limpa o silêncio filtrando pelo VALOR da coluna
    -- (`lib/wacalls/events-bridge.ts`). Zerá-la num contato anonimizado é
    -- seguro — não há chamada viva de contato anonimizado — e é a razão de
    -- esta entrega NÃO usar essa coluna para texto rico: ela continua
    -- recebendo só o código, e o texto vive em `passagens_de_atendimento`.
    last_handoff_reason = null,
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

  -- 7b. voice_calls — o TELEFONE de quem falou ao telefone (migration 0235).
  --
  -- `peer_phone` é `not null` e guarda o número da outra ponta: depois de
  -- anonimizar o contato, ele sobrevivia ligado ao `contact_id` e reidentificava
  -- a pessoa que pediu para ser esquecida. É o mesmo argumento que a foto de
  -- perfil já tinha (ver o bloco do avatar em `lib/lgpd/redact-cascade.ts`):
  -- anonimizar em toda parte menos numa é não ter anonimizado.
  --
  -- O que fica: direção, status, motivo do fim, marcas de tempo e duração. Um
  -- registro de "houve uma chamada de 12 minutos" sem número e sem dono não
  -- identifica ninguém e é o que sustenta a métrica do atendente e a fatura.
  -- `peer_phone` é NOT NULL, então recebe o rótulo, não `null`.
  update voice_calls set
    peer_phone = v_anon_label,
    owner_user_id = null,
    created_by = null,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('voice_calls', v_count);

  -- agent_cases — o que a IA escreveu SOBRE a pessoa quando travou (migration 0280).
  --
  -- O caso é o texto que a equipe lê antes de decidir: `title`, `summary` e
  -- `blocker` saem do modelo a partir da conversa, e `context_snapshot` é o
  -- recorte dessa conversa que o motor mandou para ele. Nada disso é registro de
  -- operação — é o relato do problema de uma pessoa identificável, escrito por
  -- máquina. Sem este passo, anonimizar devolvia SUCESSO com o relato intacto.
  --
  -- As três colunas de texto são `not null`: recebem rótulo e texto fixo, nunca
  -- `null` (a mesma razão de `voice_calls.peer_phone` logo acima).
  --
  -- ⚠️ `updated_at` FICA FORA DO `set`, de propósito. O cobrador de caso parado
  -- (`app/api/v1/cron/case-stale-watcher/route.ts`) lê `updated_at` como "alguém
  -- da equipe encostou neste caso". A cascata não é alguém encostando: escrever
  -- ali faria a anonimização ADIAR a cobrança de um caso que continua parado, e
  -- o efeito só apareceria como um cliente esperando mais tempo.
  --
  -- O vínculo é pela CONVERSA porque `agent_cases` não tem FK para `contacts`.
  update agent_cases set
    title = v_anon_label,
    summary = '[resumo anonimizado]',
    blocker = '[bloqueio anonimizado]',
    context_snapshot = '{}'::jsonb
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_cases', v_count);

  -- agent_case_events — a linha do tempo do caso (migration 0280).
  --
  -- `body` é o que a pessoa da equipe escreveu ao responder o caso e o que o
  -- agente registrou sobre o que o LEAD respondeu; `metadata` carrega o recorte
  -- que o motor anexou. `kind`, `actor_kind`, `human_action` e `created_at`
  -- FICAM: são o registro de que houve um toque humano e quando — operação, não
  -- dado da pessoa, e é deles que sai a métrica de atendimento.
  update agent_case_events set
    body = null,
    metadata = '{}'::jsonb
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_events', v_count);

  -- demandas — o assunto do pedido (migration 0280).
  --
  -- `assunto` é texto livre sobre o que a pessoa pediu. O resto da linha é a
  -- operação da demanda (origem, estado, dono, prazo, desfecho) e fica de pé:
  -- apagar a linha inteira tiraria da organização a resposta a "quantos pedidos
  -- houve em março", que é o mesmo argumento do compromisso da agenda.
  --
  -- FK direta (`demandas.contact_id` é `not null`), então o vínculo é o contato.
  update demandas set
    assunto = null
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('demandas', v_count);

  -- agent_inbox_items — o aviso que leva o texto do caso para a Central (migration 0280).
  --
  -- O `body` do aviso de caso parado EMBUTE o título do caso
  -- (`app/api/v1/cron/case-stale-watcher/route.ts:128`), e o do handoff embute o
  -- motivo da parada (`lib/ai/handoff/orchestrator.ts:335`). Redigir o caso e
  -- deixar o aviso de pé seria anonimizar em toda parte menos numa — que é não
  -- ter anonimizado. O molde (resolver + trocar o corpo + soltar a referência) é
  -- o de `fn_meet_redact_contact`, que já faz isto para o aviso de compromisso.
  --
  -- ⚠️ O VÍNCULO É POLIMÓRFICO E TEM TRÊS BRAÇOS, não dois. Medido nos
  -- produtores, não suposto: `handoff` nasce com `ref_kind='contact'`
  -- (`lib/ai/handoff/orchestrator.ts:339`) E com `ref_kind='conversation'`
  -- (`lib/agent-engine/agent/inbound-turn.ts:4100`); `case_stale` nasce SEMPRE
  -- com `ref_kind='agent_case'` (a rota do cron acima, e a política em
  -- `lib/ai/inbox-destino.ts:38`). Um predicado com só os dois primeiros braços
  -- casa ZERO avisos de caso parado — e casar zero linha não é erro: é sucesso
  -- com o texto intacto.
  --
  -- Os `kind` são os MEDIDOS no CHECK vigente (`supabase/baseline.sql`, bloco
  -- único de `agent_inbox_items_kind_check`). `case_opened` NÃO existe, e kind
  -- inexistente num `in (...)` também casa zero e devolve sucesso. Para
  -- reconferir sem acreditar nesta prosa:
  --   grep -n "agent_inbox_items_kind_check check" -A40 supabase/baseline.sql
  update agent_inbox_items set
    status = 'resolved',
    resolved_at = now(),
    body = 'Contato anonimizado.',
    ref_id = null
  where organization_id = p_organization_id
    -- `aviso_de_caso_nao_entregue` (migration 0292) entra AQUI e não num
    -- passo próprio: é o mesmo predicado polimórfico, e o braço
    -- `ref_kind='agent_case'` já alcança o caso do titular. O corpo do aviso
    -- embute o título do caso, que é texto sobre a pessoa.
    and kind in ('handoff', 'case_stale', 'aviso_de_caso_nao_entregue')
    and (
      (ref_kind = 'contact' and ref_id = p_contact_id)
      or (ref_kind = 'conversation' and ref_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          ))
      or (ref_kind = 'agent_case' and ref_id in (
            select id from agent_cases
              where organization_id = p_organization_id
                and conversation_id in (
                  select id from conversations
                    where contact_id = p_contact_id and organization_id = p_organization_id
                )
          ))
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_inbox_items', v_count);

  -- agent_case_chat_messages — a consulta interna da equipe à IA SOBRE o caso
  -- (migration 0281). FK DIRETA para `contacts`, então o vínculo é o titular e
  -- não precisa passar pela conversa.
  --
  -- `redacted_at is null` no `where` é o que torna o passo IDEMPOTENTE: a
  -- varredura diária de redações incompletas roda a função de novo, e sem essa
  -- condição o carimbo de QUANDO se apagou seria reescrito a cada rodada.
  --
  -- A linha NÃO é apagada, só o texto: quem abrir o caso depois continua vendo
  -- que a equipe perguntou N vezes, quando, e se a IA respondeu. Apagar a linha
  -- inteira ficaria verde num teste de "o texto sumiu" e tiraria da organização
  -- a resposta a "quanto a equipe deliberou sobre este caso".
  update agent_case_chat_messages set
    body = null,
    redacted_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id
    and redacted_at is null;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_chat_messages', v_count);

  -- passagens_de_atendimento — o BRIEFING é sobre a pessoa (migration 0291).
  --
  -- A linha guarda o que a IA concluiu sobre um atendimento de alguém
  -- identificável: o que ela entendeu que a pessoa quer (`title`), a narrativa
  -- que quem assumiu leu (`body`), as PALAVRAS LITERAIS do cliente (`notes`), o
  -- texto livre de quem passou (`content`) e o que a IA já tinha tentado
  -- (`tentativas`). Nada disso é registro de operação — é o relato do problema
  -- de uma pessoa, escrito por máquina, na tela de quem vai responder.
  --
  -- `body` é `not null` e recebe o RÓTULO, não `null` — a mesma razão de
  -- `voice_calls.peer_phone` e de `agent_cases.title` acima: coluna obrigatória
  -- anulada aborta o cascade INTEIRO, e um cascade abortado não anonimiza nada.
  --
  -- O que FICA, de propósito: `motor`, `origem`, `motivo_codigo`,
  -- `cliente_avisado`, `aviso_motivo_codigo`, `criado_em` e o par de
  -- reconhecimento. São operação — quantas passagens houve, por quê, quanto
  -- tempo até alguém assumir. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos atendimentos a IA devolveu em março, e quanto tempo esperaram".
  --
  -- O vínculo é a FK DIRETA `contact_id`: a tabela a carrega exatamente para
  -- este passo não precisar passar pela conversa.
  update passagens_de_atendimento set
    body       = v_anon_label,
    title      = null,
    notes      = null,
    content    = null,
    tentativas = '[]'::jsonb
  where organization_id = p_organization_id and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('passagens_de_atendimento', v_count);

  -- entregas_de_aviso_de_caso — o registro do aviso ao suporte (migration 0292).
  --
  -- A tabela NÃO guarda o texto do aviso (só `corpo_hash`), e a única coluna
  -- capaz de ecoar um dado da pessoa é `erro_detalhe`: ali vai o texto CRU que
  -- o transporte devolveu, truncado, e um provedor que recusa um envio costuma
  -- devolver o destinatário dentro da mensagem de erro.
  --
  -- O que FICA, de propósito: `status`, `erro_codigo`, `tentativas`,
  -- `enviado_em`, `destino`, `corpo_hash`. São operação — quantos avisos saíram,
  -- quantos falharam e por quê. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos avisos não chegaram em março". `destino` é o telefone da EQUIPE,
  -- não do titular: anonimizar um cliente não apaga o número do plantão.
  --
  -- ⚠️ PONTO CEGO DECLARADO: `tests/invariants/lgpd-cascata-alcanca-quem-
  -- guarda-pessoa.test.ts` só cobra tabela com FK para `contacts` E coluna cujo
  -- NOME case o padrão de PII. Esta tabela não satisfaz nenhuma das duas — o
  -- gate ficaria VERDE sem este passo. Ele entra porque é certo, não porque o
  -- gate cobra, e isto está escrito aqui para a próxima sessão não o remover
  -- achando que é ornamento. Quem o vigia é a catraca
  -- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
  --
  -- O vínculo é pela CONVERSA, como o de `agent_cases`: esta tabela aponta para
  -- o caso, e o caso não tem FK para `contacts`.
  update entregas_de_aviso_de_caso set
    erro_detalhe = null
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('entregas_de_aviso_de_caso', v_count);

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

-- ── travas do suporte, depois de toda tabela nova (migration 0274) ─────────
-- `config_aviso_de_caso` e `entregas_de_aviso_de_caso` nascem com a escrita
-- fechada para `anon`/`authenticated` (revoke + grant select), então o ramo
-- server-only da função lhes dá ZERO policies `support_write_*` — que é o
-- contrato mais restritivo. Escrever `drop policy` à mão aqui seria a segunda
-- representação da mesma regra.
do $f$ begin perform public.fn_aplicar_travas_de_suporte(); end $f$;

notify pgrst, 'reload schema';


-- ---- a passagem se reconhece sozinha (migration 0293) ----
--
-- DERIVADO, byte a byte, de
-- supabase/migrations/20260918130000_0293_a_passagem_se_reconhece_sozinha.sql
-- (copiado por script, nunca redigitado — ver
-- tests/unit/apendice-do-baseline-nao-diverge-da-cadeia.test.ts).
--
-- ⚠️ ENTRA ANTES DO BLOCO DA VARREDURA anon, que é de propósito o último a
-- criar função: este bloco CRIA duas, e a varredura proíbe `create function`
-- depois dela.
-- ════════════════════════════════════════════════════════════════════════════
-- 0293 — A PASSAGEM SE RECONHECE SOZINHA
-- ════════════════════════════════════════════════════════════════════════════
--
-- ─── O defeito que esta migration fecha ────────────────────────────────────
--
-- A migration 0291 criou `passagens_de_atendimento` com `reconhecido_por` /
-- `reconhecido_em`, e NINGUÉM os escrevia. Sem um escritor, três coisas ficam
-- quebradas ao mesmo tempo:
--
--   1. o cartão da conversa nunca sai do estado "esperando alguém assumir",
--      mesmo depois de alguém ter assumido;
--   2. o aviso da Central fica ABERTO para sempre — e como o aviso deduplica
--      por episódio aberto, a PRÓXIMA passagem daquela conversa não abre aviso
--      nenhum. O cliente pede um atendente de novo e ninguém é avisado;
--   3. `fn_expurgar_passagens_vencidas` só apaga linha reconhecida (é o certo:
--      passagem aberta é demanda viva), então a tabela nunca é podada.
--
-- ─── Por que um TRIGGER, e não uma chamada em cinco rotas ──────────────────
--
-- Os cinco caminhos que trocam o dono de uma conversa — assumir, transferir,
-- liberar, devolver ao automático e o rodízio por canal — passam TODOS por
-- `public.fn_conversation_assign`, que insere a linha de auditoria em
-- `conversation_assignment_events` na MESMA transação. Um gatilho ali cobre os
-- cinco sem tocar em rota nenhuma, e cobre também o sexto caminho que alguém
-- escrever amanhã.
--
-- É SQL puro: **nenhum HTTP dentro de trigger** (anti-pattern nº 9). Ele faz dois
-- `update` locais e volta.
--
-- ─── A guarda de estado, e por que ela é a SEGUNDA camada ──────────────────
--
-- A migration 0279 já revogou `insert` direto em `conversation_assignment_events`
-- de `authenticated`: pela REST ninguém forja um evento de atribuição. Esta
-- guarda fecha a INSTÂNCIA também para quem escreve com a service key: o gatilho
-- só reconhece quando a conversa REALMENTE está com aquele dono. Sem ela, uma
-- linha de auditoria incoerente (inserida à mão, ou por um script de migração de
-- dados) marcaria como "assumida" uma passagem que ninguém assumiu — e o aviso
-- da Central sumiria da lista de quem precisa agir.
--
-- ─── Portabilidade ─────────────────────────────────────────────────────────
--
-- Idempotente e portável em `psql` puro: `create or replace function`,
-- `drop trigger if exists` + `create trigger`. Sem `BEGIN`/`COMMIT` (o runner já
-- envolve). Nenhuma tabela é criada, então não há travas de suporte a reaplicar.

-- ── O gatilho: alguém assumiu a conversa ────────────────────────────────────
create or replace function public.fn_passagem_reconhecida()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- `to_user_id is null` é release/devolução ao automático: ninguém assumiu.
  -- Quem fecha esse episódio é `fn_passagem_devolvida`, chamada pela rota de
  -- "devolver ao automático" — e ela grava `reconhecido_em` SEM
  -- `reconhecido_por`, que é como a tabela distingue os dois desfechos.
  if new.to_user_id is null then
    return new;
  end if;

  -- SEGUNDA CAMADA (ver o cabeçalho): só reconhece se a conversa está mesmo com
  -- aquele dono agora. `is not distinct from` e não `=` porque os dois lados
  -- podem ser nulos em outras rotas desta mesma tabela.
  if not exists (
    select 1 from public.conversations c
     where c.id = new.conversation_id
       and c.organization_id = new.organization_id
       and c.assigned_to_user_id is not distinct from new.to_user_id
  ) then
    return new;
  end if;

  update public.passagens_de_atendimento
     set reconhecido_por = new.to_user_id,
         reconhecido_em  = now()
   where organization_id = new.organization_id
     and conversation_id = new.conversation_id
     and reconhecido_em is null;

  -- O aviso da Central se resolve junto. `ref_kind='conversation'` é a chave que
  -- os dois motores passaram a usar (a mesma da dedup) — com `contact` o aviso
  -- de um contato com duas conversas abertas era um só.
  update public.agent_inbox_items
     set status = 'resolved',
         resolved_at = now()
   where organization_id = new.organization_id
     and kind = 'handoff'
     and ref_kind = 'conversation'
     and ref_id = new.conversation_id
     and status = 'open';

  return new;
end;
$$;

-- Função nova em `public` nasce EXPOSTA por DUAS origens (o grant implícito a
-- PUBLIC do Postgres e o `ALTER DEFAULT PRIVILEGES … TO anon` do baseline), e
-- revogar só uma deixa a função alcançável com o gate verde.
revoke all on function public.fn_passagem_reconhecida() from public, anon, authenticated;

drop trigger if exists trg_passagem_reconhecida on public.conversation_assignment_events;
create trigger trg_passagem_reconhecida
  after insert on public.conversation_assignment_events
  for each row execute function public.fn_passagem_reconhecida();

-- ── A devolução ao automático: o episódio fechou sem ninguém assumir ────────
--
-- `reconhecido_em` preenchido COM `reconhecido_por` nulo é o par que a 0291
-- documentou: "devolvida ao automático (ninguém assumiu, mas o episódio
-- fechou)". O CHECK `passagens_reconhecimento_coerente` permite exatamente esse
-- lado e proíbe o inverso.
--
-- **`security definer` e não o client de sessão**: a policy da tabela é `for
-- select` apenas, e `authenticated` não tem `update` — de propósito, para que
-- ninguém reescreva um fato. E não o client de serviço porque abrir admin numa
-- rota quando há molde de definer no repositório é privilégio a mais sem
-- necessidade. A autorização mora NO CORPO.
create or replace function public.fn_passagem_devolvida(
  p_organization_id uuid,
  p_conversation_id uuid
) returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fechadas integer;
begin
  -- Mesmo padrão de `fn_conversation_assign`: quando há sessão, ela precisa ser
  -- de um membro `agent`+ da organização. Sem sessão (worker com service key) a
  -- checagem não se aplica — quem tem a chave já tem tudo.
  if auth.uid() is not null
     and not public.fn_role_at_least(p_organization_id, 'agent') then
    raise exception 'caller_not_authorized_for_org'
      using hint = 'caller must be an active agent+ member of the organization';
  end if;

  update public.passagens_de_atendimento
     set reconhecido_em = now()
   where organization_id = p_organization_id
     and conversation_id = p_conversation_id
     and reconhecido_em is null;
  get diagnostics v_fechadas = row_count;

  update public.agent_inbox_items
     set status = 'resolved',
         resolved_at = now()
   where organization_id = p_organization_id
     and kind = 'handoff'
     and ref_kind = 'conversation'
     and ref_id = p_conversation_id
     and status = 'open';

  return v_fechadas;
end;
$$;

revoke all     on function public.fn_passagem_devolvida(uuid, uuid) from public, anon;
grant  execute on function public.fn_passagem_devolvida(uuid, uuid) to authenticated, service_role;

-- ---- o cliente repetiu depois da passagem + o contador do cobrador (migration 0294) ----
-- ═══════════════════════════════════════════════════════════════════════════
-- 0294 — O LAÇO DE RETORNO DA PASSAGEM, e o contador que cala o cobrador.
--
-- ─── O que esta migration responde ────────────────────────────────────────
--
-- A entrega da passagem (0291, 0293) fez a IA gravar POR QUE parou, o que já
-- tentou e o que o cliente quer, e pôs esse texto na frente de quem assume. A
-- pergunta que ela ainda não respondia é a única que diz se aquilo serviu para
-- alguma coisa: **depois de a IA passar a conversa, o cliente precisou repetir
-- o que já tinha dito?**
--
-- Se o briefing chegou, a repetição cai. Se não chegou, ela não muda — e a
-- feature é decoração cara. Sem este número, a única evidência de sucesso seria
-- alguém achar o cartão bonito.
--
-- ─── POR QUE NÃO UMA TABELA DE MÉTRICA, NEM UM PAINEL NOVO ────────────────
--
-- O instrumento já existe e está calibrado: `fn_atrito_jaccard(a,b)` (0135),
-- `immutable`, com limiar `p_repeticao_min` default 0.7 escolhido para zero
-- falso positivo. `fn_atrito_metrics` já o usa para a repergunta dentro do
-- Índice de Atrito, já roda SECURITY INVOKER (logo a RLS da tabela nova vale) e
-- já devolve `jsonb` — onde acrescentar chave não quebra leitor antigo. Uma
-- tabela de agregado seria um número sincronizado por cron onde cabe uma
-- consulta, que é o anti-pattern nº 5 do CLAUDE.md.
--
-- ─── AS DUAS CHAVES, E POR QUE SÃO DUAS ──────────────────────────────────
--
--   `repeticao_pos_passagem` — numerador: passagens em que o cliente repetiu;
--   `passagens_medidas`      — denominador: passagens em que ele voltou a falar.
--
-- A razão NÃO é calculada aqui. Ela é montada em `lib/metrics/atrito.ts`, que é
-- onde mora a regra "denominador zero devolve null, nunca 0". Uma razão
-- calculada no SQL devolveria `0/0` como `null` por acaso e `0/1` como `0` por
-- acidente — e a tela não teria como distinguir "ninguém repetiu" de "ninguém
-- voltou a falar". Publicar os dois números é o que torna a régua auditável por
-- quem lê a tela, não só por quem lê este arquivo.
--
-- ⚠️ A RESSALVA QUE VIAJA COM O NÚMERO (e que a tela publica na `nota`):
-- `fn_atrito_metrics` é **SECURITY INVOKER**. Um `agent` numa organização em
-- `visibility_mode='own'` enxerga o número só das conversas dele; `manager` e
-- `admin` enxergam o da organização. Dois papéis veem números diferentes de
-- boa-fé, e quem comparar sem saber disso vai achar que um deles está errado.
--
-- ─── A SEGUNDA COISA: `cobrancas` ────────────────────────────────────────
--
-- O reconhecimento da passagem (0293) só acontece por gesto de quem CHEGOU.
-- Ninguém cobra a passagem em que ninguém chegou — e dos treze caminhos que
-- passam conversa para uma pessoa, UM nasce de caso, então o
-- `case-stale-watcher` não alcança os outros doze nem por acidente. A população
-- já foi medida num CRM em produção com o mesmo desenho de fila (2026-09-14):
-- 22 pedidos parados, o mais antigo há 17,6 dias, e ONZE deles eram gente
-- pedindo para falar com uma pessoa.
--
-- O conserto é um segundo braço no MESMO cron, e ele precisa de um lugar para
-- guardar quantas vezes já cobrou — senão o alarme nunca cala, e alarme que
-- nunca cala treina a equipe a ignorar o alarme certo. `agent_cases` tem
-- `followup_attempts` para isso; `passagens_de_atendimento` não tinha nada.
--
-- DIRC, respondida: Duplicar — não, o contador é desta linha e de mais nada;
-- Integrar — não há de onde vir (o aviso da Central não conta tentativa);
-- Referenciar — não é ponteiro; Calcular — não dá: a cobrança não deixa rastro
-- próprio em lugar nenhum, e inferi-la por idade cobraria de novo o que já foi
-- cobrado três vezes.
--
-- ─── REAPLICAÇÃO ─────────────────────────────────────────────────────────
--
-- `add column if not exists` com default (aplicável a tabela COM linhas) e
-- `create or replace function` com a MESMA assinatura. O `update.sh` de um
-- clone reaplica sem erro e sem duplicar efeito. Nenhuma constraint nova sobre
-- dados existentes ⇒ não há deduplicação prévia a fazer (regra 8 da doutrina).
--
-- O corpo de `fn_atrito_metrics` abaixo é DERIVADO do corpo vigente por script
-- (`scratchpad/onda11/montar-0294.py`), nunca redigitado: duas edições, as duas
-- provadas reversíveis ao byte antes de o arquivo ser escrito.
-- ═══════════════════════════════════════════════════════════════════════════

-- Quantas vezes o vigia já cobrou ESTA passagem. Teto de 3 no chamador
-- (`app/api/v1/cron/case-stale-watcher/route.ts`), pelo mesmo argumento de
-- `agent_cases.followup_attempts`: quem ignorou três vezes não atende no quarto.
alter table public.passagens_de_atendimento
  add column if not exists cobrancas int not null default 0;


drop function if exists public.fn_atrito_metrics(uuid, timestamptz, timestamptz, int, float8, int);

create or replace function public.fn_atrito_metrics(
  p_org uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_abandono_horas int default 72,
  p_repeticao_min float8 default 0.7,
  p_espera_horas int default 4
) returns jsonb
language sql stable
set search_path = public
as $$
  with
  -- DENOMINADOR DEFINITIVO: demandas encerradas na janela. Não mais os casos.
  demandas_j as (
    select d.id, d.agent_case_id, d.aberta_em, d.fechada_em, d.desfecho
      from public.demandas d
     where d.organization_id = p_org
       and d.fechada_em is not null
       and d.fechada_em >= p_from
       and d.fechada_em <  p_to
  ),
  -- Turnos: mensagens de TODAS as conversas da demanda (N:N), dentro da vida
  -- dela. Uma demanda que atravessou dois canais soma os dois.
  turnos as (
    select d.id,
           (select count(*)
              from public.demanda_conversas dc
              join public.messages m
                on m.conversation_id = dc.conversation_id
               and m.organization_id = p_org
               and m.sent_at >= d.aberta_em
               and m.sent_at <  d.fechada_em
             where dc.demanda_id = d.id) as n
      from demandas_j d
  ),
  -- Insistência: só existe onde houve caso. O payload declara o denominador
  -- próprio (`demandas_com_caso`) para o número não ser lido como se fosse
  -- sobre o total.
  insistencia as (
    select avg(c.followup_attempts)::float8 as media,
           max(c.followup_attempts)         as maximo,
           count(*)                         as base
      from demandas_j d
      join public.agent_cases c on c.id = d.agent_case_id
  ),
  humano as (
    select e.case_id, count(*) as intervencoes, min(e.created_at) as primeiro_toque
      from public.agent_case_events e
      join demandas_j d on d.agent_case_id = e.case_id
     where e.organization_id = p_org and e.actor_kind = 'human'
     group by e.case_id
  ),
  espera_fila as (
    select extract(epoch from (h.primeiro_toque - d.aberta_em)) as segundos
      from demandas_j d join humano h on h.case_id = d.agent_case_id
     where h.primeiro_toque > d.aberta_em
  ),
  retrabalho as (
    select count(distinct e.case_id) as n
      from public.agent_case_events e
      join demandas_j d on d.agent_case_id = e.case_id
     where e.organization_id = p_org
       and (e.kind = 'escalated' or e.human_action = 'escalate')
  ),
  abandono as (
    select
      count(*) filter (
        where cv.last_outbound_at >= p_from and cv.last_outbound_at < p_to
          and (cv.last_inbound_at is null or cv.last_outbound_at > cv.last_inbound_at)
          and cv.last_outbound_at < now() - make_interval(hours => p_abandono_horas)
          and cv.status not in ('resolved', 'closed')
      ) as abandonadas,
      count(*) filter (
        where cv.last_outbound_at >= p_from and cv.last_outbound_at < p_to
      ) as com_fala_nossa
      from public.conversations cv
     where cv.organization_id = p_org and cv.last_outbound_at is not null
  ),
  -- INVARIANTE 4, agora VERIFICÁVEL: demanda aberta sem próximo passo é o
  -- vazamento que a doutrina proíbe. Antes da 0119 isto não era enumerável.
  sem_proximo_passo as (
    select count(*) as n
      from public.demandas d
     where d.organization_id = p_org
       and d.fechada_em is null
       and d.proximo_passo is null
  ),
  demandas_abertas as (
    select count(*) as n from public.demandas d
     where d.organization_id = p_org and d.fechada_em is null
  ),
  inbounds as (
    select m.conversation_id, m.sent_at, m.body,
           lag(m.body)    over (partition by m.conversation_id order by m.sent_at) as body_anterior,
           lag(m.sent_at) over (partition by m.conversation_id order by m.sent_at) as sent_at_anterior
      from public.messages m
     where m.organization_id = p_org and m.direction = 'inbound' and m.body is not null
       and m.sent_at >= p_from and m.sent_at < p_to
  ),
  repeticao as (
    select
      count(*) filter (
        where i.body_anterior is not null
          and exists (select 1 from public.messages o
                       where o.organization_id = p_org and o.conversation_id = i.conversation_id
                         and o.direction = 'outbound'
                         and o.sent_at > i.sent_at_anterior and o.sent_at < i.sent_at)
          and public.fn_atrito_jaccard(i.body, i.body_anterior) >= p_repeticao_min
      ) as repetidas,
      count(*) filter (
        where i.body_anterior is not null
          and exists (select 1 from public.messages o
                       where o.organization_id = p_org and o.conversation_id = i.conversation_id
                         and o.direction = 'outbound'
                         and o.sent_at > i.sent_at_anterior and o.sent_at < i.sent_at)
      ) as com_resposta_no_meio
      from inbounds i
  ),
  espera_calada as (
    select count(*) filter (where prox.espera_s > p_espera_horas * 3600) as caladas,
           count(*) as com_resposta,
           percentile_cont(0.9) within group (order by prox.espera_s) as p90_s
      from (
        select extract(epoch from (
                 (select min(o.sent_at) from public.messages o
                   where o.organization_id = p_org and o.conversation_id = m.conversation_id
                     and o.direction = 'outbound' and o.sent_at > m.sent_at) - m.sent_at)) as espera_s
          from public.messages m
         where m.organization_id = p_org and m.direction = 'inbound'
           and m.sent_at >= p_from and m.sent_at < p_to
      ) prox
     where prox.espera_s is not null
  ),
  envios as (
    select count(*) filter (where m.sent_via = 'ai')              as por_ia,
           count(*) filter (where m.sent_via = 'automation')      as por_automacao,
           count(*) filter (where m.sent_via = 'system')          as por_integracao,
           count(*) filter (where m.sent_via = 'user')            as por_humano_no_sistema,
           count(*) filter (where m.sent_via = 'external_device') as por_humano_fora
      from public.messages m
     where m.organization_id = p_org and m.direction = 'outbound'
       and m.sent_at >= p_from and m.sent_at < p_to
  ),
  vetos as (
    select count(*) filter (where t.vetoed_gate is not null) as vetados,
           count(distinct t.job_id) as execucoes
      from public.before_send_traces t
     where t.organization_id = p_org and t.created_at >= p_from and t.created_at < p_to
  ),
  descadastros as (
    select count(*) as n from public.contacts c
     where c.organization_id = p_org and c.blocked_at is not null
       and c.blocked_at >= p_from and c.blocked_at < p_to
  ),
  pedidos_humano as (
    select count(*) as n from public.crm_lead_activities a
     where a.organization_id = p_org and a.type = 'handoff_triggered'
       and a.performed_at >= p_from and a.performed_at < p_to
  ),
  -- ─── O LAÇO DE RETORNO DA PASSAGEM (migration 0294) ──────────────────────
  -- A pergunta que mede se o briefing serviu para alguma coisa: DEPOIS de a IA
  -- passar a conversa, o cliente precisou repetir o que já tinha dito? Se o
  -- contexto chegou a quem assumiu, a repetição cai; se não chegou, ela não
  -- muda — e a feature é decoração.
  --
  -- A RÉGUA, escrita para o número não envelhecer:
  --   · limiar         = `p_repeticao_min` (0.7), o MESMO do índice de
  --                      repergunta — dois limiares para o mesmo fenômeno
  --                      fariam dois números incomparáveis na mesma tela;
  --   · janela         = 24 h depois da passagem. Mais que isso já é outra
  --                      conversa; menos deixaria de fora o atendente que
  --                      assumiu no dia seguinte;
  --   · denominador    = passagens em que o cliente VOLTOU A FALAR. Sem fala
  --                      nova não há repetição a medir, e contá-las como "não
  --                      repetiu" inflaria o número para o lado bonito. É a
  --                      mesma regra de `lib/metrics/atrito.ts`: ausência de
  --                      dado é `null`, nunca `0` — e é a razão de as DUAS
  --                      chaves saírem daqui (numerador e denominador), em vez
  --                      de uma razão já calculada.
  repeticao_pos_passagem as (
    select count(*) filter (where r.repetiu) as repetidas,
           count(*)                          as medidas
      from (
        select p.id,
               exists (
                 select 1
                   from public.messages depois
                   join public.messages antes
                     on antes.organization_id = depois.organization_id
                    and antes.conversation_id = depois.conversation_id
                    and antes.direction = 'inbound'
                    and antes.body is not null
                    and antes.sent_at < p.criado_em
                  where depois.organization_id = p.organization_id
                    and depois.conversation_id = p.conversation_id
                    and depois.direction = 'inbound'
                    and depois.body is not null
                    and depois.sent_at > p.criado_em
                    and depois.sent_at < p.criado_em + interval '24 hours'
                    and public.fn_atrito_jaccard(depois.body, antes.body) >= p_repeticao_min
               ) as repetiu
          from public.passagens_de_atendimento p
         where p.organization_id = p_org
           and p.criado_em >= p_from and p.criado_em < p_to
           and exists (
             select 1 from public.messages m
              where m.organization_id = p.organization_id
                and m.conversation_id = p.conversation_id
                and m.direction = 'inbound'
                and m.body is not null
                and m.sent_at > p.criado_em
                and m.sent_at < p.criado_em + interval '24 hours'
           )
      ) r
  ),
  eficiencia as (
    select count(*) filter (where status = 'won')  as ganhos,
           count(*) filter (
             where status = 'lost'
               -- A transferência entre funis não é perda comercial (migration 0266).
               and coalesce(lost_reason, '') <> 'moved_to_another_pipeline'
           ) as perdidos
      from public.crm_leads
     where organization_id = p_org and status in ('won', 'lost')
       and closed_at >= p_from and closed_at < p_to
  )
  select jsonb_build_object(
    'escopo', jsonb_build_object(
      'demandas',            (select count(*) from demandas_j),
      'demandas_com_caso',   (select base from insistencia),
      'demandas_abertas',    (select n from demandas_abertas),
      'de', p_from, 'ate', p_to,
      'abandono_horas', p_abandono_horas,
      'repeticao_min',  p_repeticao_min,
      'espera_horas',   p_espera_horas,
      -- Marca a régua do denominador: quem comparar dois períodos precisa saber
      -- se foram medidos sobre casos ou sobre demandas.
      'denominador', 'demandas'
    ),
    'cliente', jsonb_build_object(
      'turnos_p50',        (select percentile_cont(0.5) within group (order by n) from turnos),
      'turnos_p90',        (select percentile_cont(0.9) within group (order by n) from turnos),
      'insistencia_media', (select media  from insistencia),
      'insistencia_max',   (select maximo from insistencia),
      'pedidos_de_humano', (select n from pedidos_humano),
      'descadastros',      (select n from descadastros),
      'abandonos',         (select abandonadas   from abandono),
      'conversas_com_fala_nossa', (select com_fala_nossa from abandono),
      'reperguntas',              (select repetidas            from repeticao),
      'perguntas_com_resposta',   (select com_resposta_no_meio from repeticao),
      'esperas_caladas',          (select caladas      from espera_calada),
      'esperas_medidas',          (select com_resposta from espera_calada),
      'espera_resposta_p90_s',    (select p90_s        from espera_calada),
      -- As duas chaves do laço da passagem (0294). Numerador e denominador
      -- SEPARADOS de propósito: a razão é calculada na borda, que é onde
      -- mora a regra de devolver `null` quando o denominador é zero.
      'repeticao_pos_passagem',   (select repetidas from repeticao_pos_passagem),
      'passagens_medidas',        (select medidas   from repeticao_pos_passagem)
    ),
    'empresa', jsonb_build_object(
      'intervencoes_por_demanda', (select avg(coalesce(h.intervencoes, 0))::float8
                                     from demandas_j d left join humano h on h.case_id = d.agent_case_id),
      'espera_humana_p50_s',      (select percentile_cont(0.5) within group (order by segundos) from espera_fila),
      'espera_humana_p90_s',      (select percentile_cont(0.9) within group (order by segundos) from espera_fila),
      'retrabalho',               (select n from retrabalho),
      'vetos',                    (select vetados  from vetos),
      'execucoes_medidas',        (select execucoes from vetos),
      'envios_por_ia',            (select por_ia                from envios),
      'envios_por_automacao',     (select por_automacao         from envios),
      'envios_por_integracao',    (select por_integracao        from envios),
      'envios_humano_no_sistema', (select por_humano_no_sistema from envios),
      'envios_humano_fora',       (select por_humano_fora       from envios),
      -- O invariante 4 vira NÚMERO na tela: demanda aberta sem próximo passo é
      -- vazamento, e vazamento invisível é o que a doutrina inteira combate.
      'demandas_sem_proximo_passo', (select n from sem_proximo_passo)
    ),
    'eficiencia', jsonb_build_object(
      'ganhos',   (select ganhos   from eficiencia),
      'perdidos', (select perdidos from eficiencia)
    )
  );
$$;

revoke all     on function public.fn_atrito_metrics(uuid, timestamptz, timestamptz, int, float8, int) from public;
revoke execute on function public.fn_atrito_metrics(uuid, timestamptz, timestamptz, int, float8, int) from anon;
grant  execute on function public.fn_atrito_metrics(uuid, timestamptz, timestamptz, int, float8, int)
  to authenticated, service_role;


-- ---- o banco conhece o perfil declarativo v2 das extensões (migration 0282) ----
-- 0282 — O banco passa a conhecer o perfil declarativo v2 (ADR-0003)
--
-- POR QUE ESTA MIGRATION EXISTE, e por que a ADR-0003 dizia que ela não existiria.
--
-- A ADR afirmou "esta ADR não altera o schema", apoiada numa medição PARCIAL: li a validação
-- do MANIFESTO (0271:356-357), vi que ela fecha o conjunto de CHAVES e não o conteúdo delas,
-- e concluí sobre o sistema inteiro. Faltou ler até o efeito. A validação do CATÁLOGO, dentro
-- de `fn_extensions_admit_catalog`, faz duas coisas que a do manifesto não faz:
--
--   0271:194   v_entry->'permissions' <> '["navigation.tasks"]'::jsonb   -- valor FIXO
--   0271:184   v_entry - array[...9 chaves...] <> '{}'::jsonb            -- chave nova é erro
--
-- Efeito medido: sem esta migration, um catálogo do perfil v2 é RECUSADO pelo banco — tanto
-- por declarar outra permissão quanto por trazer o metadado de loja. O contrato novo viveria
-- só no TypeScript, e a admissão falharia com `extension_invalid_input`.
--
-- O QUE MUDA
--
-- 1. Permissões viram conjunto fechado, o mesmo de `lib/extensions/capacidades.ts`: lista não
--    vazia, sem repetição, sem valor desconhecido. A mesma regra dos dois lados.
-- 2. As cinco chaves de loja passam a ser aceitas NO CATÁLOGO. No manifesto continuam
--    recusadas: o pacote descreve o que faz, o catálogo revisado descreve de quem é.
-- 3. `extension_permissions_changed` passa a existir de verdade, em atualizar e em desfazer.
--
-- As três funções são reescritas INTEIRAS, com o corpo da 0271 preservado e as alterações
-- aplicadas aqui, no arquivo — e não por substituição de texto em tempo de execução lendo o
-- `prosrc` do banco, que dependeria do estado de cada clone e falharia em silêncio.
--
-- Idempotente: `create or replace` em todas. Reaplicar não duplica efeito.

create or replace function public.fn_extensions_permissoes_validas(p_permissions jsonb)
returns boolean language sql immutable set search_path = public, pg_temp as $$
  select p_permissions is not null
    and jsonb_typeof(p_permissions) = 'array'
    and jsonb_array_length(p_permissions) between 1 and 6
    and not exists (
      select 1 from jsonb_array_elements(p_permissions) e
      where jsonb_typeof(e.value) <> 'string'
         or e.value #>> '{}' not in (
              'navigation.tasks', 'navigation.inbox', 'navigation.kanban',
              'navigation.contacts', 'navigation.agenda', 'navigation.radar')
    )
    and (select count(distinct e.value) from jsonb_array_elements(p_permissions) e)
        = jsonb_array_length(p_permissions);
$$;

revoke execute on function public.fn_extensions_permissoes_validas(jsonb) from public, anon;
revoke execute on function public.fn_extensions_permissoes_validas(jsonb) from authenticated;
grant execute on function public.fn_extensions_permissoes_validas(jsonb) to service_role;

create or replace function public.fn_extensions_admit_catalog(p_actor uuid, p_operation uuid, p_snapshot jsonb, p_digest text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_request jsonb := jsonb_build_object('kind','catalog_admission','actor',p_actor,'snapshot',p_snapshot,'digest',p_digest);
  v_op public.extension_operations; v_catalog public.extension_catalogs; v_entry jsonb; v_revision integer;
begin
  perform public.fn_extensions_assert_actor(p_actor);
  if p_operation is null then raise exception using errcode='P0001', message='extension_invalid_input'; end if;
  perform pg_advisory_xact_lock(255,1);
  perform public.fn_extensions_assert_actor(p_actor);
  perform pg_advisory_xact_lock(hashtextextended(p_operation::text,255));
  perform public.fn_extensions_assert_actor(p_actor);
  select * into v_op from public.extension_operations where id=p_operation;
  if found then
    if v_op.request_fingerprint <> public.fn_extensions_fingerprint(v_request) then
      raise exception using errcode='P0001', message='extension_idempotency_conflict';
    end if;
    return to_jsonb(v_op) || jsonb_build_object('applied_now', false);
  end if;
  if p_snapshot is null or jsonb_typeof(p_snapshot) <> 'object'
    or not (p_snapshot ?& array['format_version','origin','revision','entries'])
    or p_snapshot - array['format_version','origin','revision','entries'] <> '{}'::jsonb
    or p_snapshot->'format_version' is distinct from '1'::jsonb
    or jsonb_typeof(p_snapshot->'origin') is distinct from 'string'
    or p_snapshot->>'origin' !~ '^https?://[^/@?#[:space:]]+$'
    or jsonb_typeof(p_snapshot->'revision') is distinct from 'number'
    or p_snapshot->>'revision' !~ '^[1-9][0-9]{0,8}$'
    or jsonb_typeof(p_snapshot->'entries') is distinct from 'array'
    or p_digest is null or p_digest !~ '^[a-f0-9]{64}$' then
    raise exception using errcode='P0001', message='extension_invalid_input';
  end if;
  if jsonb_array_length(p_snapshot->'entries') > 128 then
    raise exception using errcode='P0001', message='extension_invalid_input';
  end if;
  for v_entry in select value from jsonb_array_elements(p_snapshot->'entries') loop
    if jsonb_typeof(v_entry) <> 'object' or not (v_entry ?& array['publisher','name','version','license','host_api','display','permissions','sha256','byte_length'])
      or v_entry - array['publisher','name','version','license','host_api','display','permissions','sha256','byte_length','publisher_label','homepage','repository','tags','published_at'] <> '{}'::jsonb
      or exists (select 1 from jsonb_each(v_entry) e where e.value='null'::jsonb)
      or jsonb_typeof(v_entry->'byte_length') is distinct from 'number'
      or jsonb_typeof(v_entry->'host_api') is distinct from 'object'
      or jsonb_typeof(v_entry->'display') is distinct from 'object'
      or v_entry->>'publisher' !~ '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$'
      or v_entry->>'name' !~ '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$'
      or v_entry->>'version' !~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
      or v_entry->>'sha256' !~ '^[a-f0-9]{64}$'
      or v_entry->>'byte_length' !~ '^[1-9][0-9]{0,4}$'
      or v_entry->>'license' <> 'MIT' or not public.fn_extensions_permissoes_validas(v_entry->'permissions') then
      raise exception using errcode='P0001', message='extension_invalid_input';
    end if;
    if (v_entry->>'byte_length')::integer > 65536 then
      raise exception using errcode='P0001', message='extension_invalid_input';
    end if;
  end loop;
  if exists (select 1 from jsonb_array_elements(p_snapshot->'entries') e
    group by e->>'publisher', e->>'name', e->>'version' having count(*) > 1) then
    raise exception using errcode='P0001', message='extension_invalid_input';
  end if;
  v_revision := (p_snapshot->>'revision')::integer;
  select * into v_catalog from public.extension_catalogs where origin=p_snapshot->>'origin';
  if found and (v_revision < v_catalog.revision or (v_revision = v_catalog.revision
      and (p_digest <> v_catalog.digest or p_snapshot <> v_catalog.snapshot))) then
    raise exception using errcode='P0001', message='extension_catalog_revision_conflict';
  end if;
  if v_catalog.id is null then
    if (select count(*) from public.extension_catalogs) >= 8 then
      raise exception using errcode='P0001',message='extension_catalog_limit';
    end if;
    insert into public.extension_catalogs(origin,revision,digest,snapshot,admitted_by)
      values(p_snapshot->>'origin',v_revision,p_digest,p_snapshot,p_actor) returning * into v_catalog;
  elsif v_revision > v_catalog.revision then
    update public.extension_catalogs set revision=v_revision,digest=p_digest,snapshot=p_snapshot,
      admitted_by=p_actor,admitted_at=now() where id=v_catalog.id returning * into v_catalog;
    update public.extension_operations set status='cancelled',error_code='extension_catalog_stale',updated_at=now()
      where catalog_id=v_catalog.id and kind in ('install','update') and status='preparing';
  end if;
  insert into public.extension_operations(id,kind,status,actor_id,catalog_id,request,request_fingerprint,result)
    values(p_operation,'catalog_admission','completed',p_actor,v_catalog.id,v_request,
      public.fn_extensions_fingerprint(v_request),jsonb_build_object('catalog',to_jsonb(v_catalog))) returning * into v_op;
  return to_jsonb(v_op) || jsonb_build_object('applied_now', true);
end $$;

create or replace function public.fn_extensions_finish_install(p_actor uuid, p_operation uuid, p_manifest jsonb, p_sha256 text, p_byte_length integer, p_document text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_op public.extension_operations; v_catalog public.extension_catalogs;
  v_artifact public.extension_artifacts; v_install public.extension_installations; v_current public.extension_artifacts;
  v_previous public.extension_artifacts; v_document_json jsonb; v_active integer := 0;
begin
  perform public.fn_extensions_assert_actor(p_actor);
  perform pg_advisory_xact_lock(255,1);
  perform public.fn_extensions_assert_actor(p_actor);
  select * into v_op from public.extension_operations where id=p_operation for update;
  if not found then raise exception using errcode='P0001',message='extension_operation_not_found'; end if;
  if v_op.kind not in ('install','update') or v_op.actor_id is distinct from p_actor then
    raise exception using errcode='P0001',message='extension_operation_conflict';
  end if;
  -- Sem autoridade após cancel/fail. Resposta perdida de completed segue verificando payload.
  if v_op.status in ('cancelled','failed') then return to_jsonb(v_op) || jsonb_build_object('applied_now', false); end if;
  if p_document is null or octet_length(p_document) not between 1 and 65536
    or octet_length(p_document) is distinct from p_byte_length
    or encode(sha256(convert_to(p_document,'UTF8')),'hex') is distinct from p_sha256 then
    raise exception using errcode='P0001',message='extension_artifact_mismatch';
  end if;
  begin
    v_document_json := p_document::jsonb;
  exception when invalid_text_representation or untranslatable_character or program_limit_exceeded then
    raise exception using errcode='P0001',message='extension_artifact_mismatch';
  end;
  if v_document_json is distinct from p_manifest then
    raise exception using errcode='P0001',message='extension_artifact_mismatch';
  end if;
  if p_sha256 is distinct from v_op.entry->>'sha256' or p_byte_length is distinct from (v_op.entry->>'byte_length')::integer
    or p_manifest is null or jsonb_typeof(p_manifest) <> 'object'
    or not (p_manifest ?& array['format_version','profile','publisher','name','version','license','host_api','permissions','dependencies','data','display','configuration','contributions'])
    or p_manifest - array['format_version','profile','publisher','name','version','license','host_api','permissions','dependencies','data','display','configuration','contributions'] <> '{}'::jsonb
    or exists (select 1 from jsonb_each(p_manifest) e where e.value='null'::jsonb)
    or p_manifest->'format_version' is distinct from '1'::jsonb or p_manifest->>'profile' is distinct from 'declarative'
    or jsonb_typeof(p_manifest->'configuration') is distinct from 'object'
    or jsonb_typeof(p_manifest->'contributions') is distinct from 'object'
    or p_manifest->>'publisher' is distinct from v_op.publisher or p_manifest->>'name' is distinct from v_op.name
    or p_manifest->>'version' is distinct from v_op.version
    or p_manifest->'dependencies' <> '[]'::jsonb or p_manifest->'data' <> '{"mode":"none"}'::jsonb
    or (p_manifest - array['format_version','profile','dependencies','data','configuration','contributions'])
      is distinct from (v_op.entry - array['sha256','byte_length']) then
    raise exception using errcode='P0001',message='extension_artifact_mismatch';
  end if;
  if v_op.status='completed' then
    -- Compara com o artefato que ESTA conclusão publicou, não com o ponteiro de agora: um
    -- "desfazer" posterior não pode fazer a repetição acusar pacote adulterado.
    select * into v_artifact from public.extension_artifacts
      where id=coalesce(v_op.result->>'to_artifact_id', v_op.result->'installation'->>'artifact_id')::uuid;
    if not found or v_artifact.manifest is distinct from p_manifest or v_artifact.document is distinct from p_document then
      raise exception using errcode='P0001',message='extension_artifact_mismatch';
    end if;
    return to_jsonb(v_op) || jsonb_build_object('applied_now', false);
  end if;
  if public.fn_extensions_core_update_in_progress() then
    raise exception using errcode='P0001',message='extension_core_update_in_progress';
  end if;
  select * into v_catalog from public.extension_catalogs where id=v_op.catalog_id;
  if v_catalog.revision is distinct from v_op.admission_revision or v_catalog.digest is distinct from v_op.admission_digest then
    raise exception using errcode='P0001',message='extension_catalog_stale';
  end if;
  select * into v_install from public.extension_installations
    where catalog_id=v_op.catalog_id and publisher=v_op.publisher and name=v_op.name for update;
  -- Defesa estrutural: a linha tem de estar na revisão que a preparação viu.
  if v_install.revision is distinct from (v_op.result->>'from_revision')::integer
    or (v_op.kind='update' and v_install.removed_at is not null)
    or (v_op.kind='install' and v_install.id is not null and v_install.removed_at is null) then
    raise exception using errcode='P0001',message='extension_version_changed';
  end if;
  if v_install.id is not null then
    select * into v_current from public.extension_artifacts where id=v_install.artifact_id;
    -- A recusa que a spec v1 prometeu para "quando o contrato admitir outra permissão".
    -- Sem ela, 1.0 -> 1.1 acrescentaria uma porta sem ninguém na organização rever a lista
    -- que a tela existe para mostrar: o furo entra pela porta lateral da própria propriedade
    -- que a lista de permissões garante. Mudar o conjunto de portas é outra extensão.
    if v_op.kind='update' and v_current.id is not null
      and v_current.manifest->'permissions' is distinct from p_manifest->'permissions' then
      raise exception using errcode='P0001',message='extension_permissions_changed';
    end if;
    select * into v_previous from public.extension_artifacts where id=v_install.previous_artifact_id;
    if (v_install.version = v_op.version and v_current.sha256 <> p_sha256)
      or (v_previous.id is not null and v_previous.manifest->>'version' = v_op.version and v_previous.sha256 <> p_sha256) then
      raise exception using errcode='P0001',message='extension_version_conflict';
    end if;
  end if;
  select * into v_artifact from public.extension_artifacts where sha256=p_sha256;
  if found then
    if v_artifact.manifest is distinct from p_manifest or v_artifact.document is distinct from p_document or v_artifact.byte_length <> p_byte_length then
      raise exception using errcode='P0001',message='extension_artifact_mismatch';
    end if;
  else
    insert into public.extension_artifacts(sha256,byte_length,manifest,document) values(p_sha256,p_byte_length,p_manifest,p_document) returning * into v_artifact;
  end if;
  if v_install.id is null then
    insert into public.extension_installations(catalog_id,artifact_id,publisher,name,version,installed_by)
      values(v_op.catalog_id,v_artifact.id,v_op.publisher,v_op.name,v_op.version,p_actor) returning * into v_install;
  elsif v_op.kind='install' then
    -- Reinstalação de uma linha removida: os vínculos NÃO voltam ativos; cada organização decide.
    update public.extension_installations set artifact_id=v_artifact.id, version=v_op.version, previous_artifact_id=null,
      removed_at=null, removed_by=null, installed_by=p_actor, installed_at=now(), revision=revision+1
      where id=v_install.id returning * into v_install;
  else
    update public.extension_installations set previous_artifact_id=artifact_id, artifact_id=v_artifact.id,
      version=v_op.version, revision=revision+1 where id=v_install.id returning * into v_install;
    select count(*)::integer into v_active from public.organization_extensions where installation_id=v_install.id and enabled;
  end if;
  update public.extension_operations set status='completed',installation_id=v_install.id,
    result=coalesce(v_op.result,'{}'::jsonb) || jsonb_build_object('installation',to_jsonb(v_install),
      'to_artifact_id',v_artifact.id,'to_version',v_op.version,'organizations_active',v_active),
    updated_at=now() where id=p_operation returning * into v_op;
  return to_jsonb(v_op) || jsonb_build_object('applied_now', true);
end $$;

create or replace function public.fn_extensions_revert_install(p_actor uuid, p_operation uuid, p_installation uuid,
  p_expected_installation_revision integer)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_request jsonb := jsonb_build_object('kind','revert','actor',p_actor,'installation',p_installation,
    'expected_installation_revision',p_expected_installation_revision);
  v_op public.extension_operations; v_install public.extension_installations; v_from public.extension_installations;
  v_target public.extension_artifacts; v_active integer;
begin
  perform public.fn_extensions_assert_actor(p_actor);
  if p_operation is null or p_installation is null or p_expected_installation_revision is null
    or p_expected_installation_revision < 1 then
    raise exception using errcode='P0001',message='extension_invalid_input';
  end if;
  perform pg_advisory_xact_lock(255,1);
  perform public.fn_extensions_assert_actor(p_actor);
  perform pg_advisory_xact_lock(hashtextextended(p_operation::text,255));
  perform public.fn_extensions_assert_actor(p_actor);
  select * into v_op from public.extension_operations where id=p_operation;
  if found then
    if v_op.request_fingerprint <> public.fn_extensions_fingerprint(v_request) then
      raise exception using errcode='P0001',message='extension_idempotency_conflict';
    end if;
    return to_jsonb(v_op) || jsonb_build_object('applied_now', false);
  end if;
  if public.fn_extensions_core_update_in_progress() then
    raise exception using errcode='P0001',message='extension_core_update_in_progress';
  end if;
  select * into v_install from public.extension_installations where id=p_installation for update;
  if not found then raise exception using errcode='P0001',message='extension_installation_not_found'; end if;
  if v_install.removed_at is not null then raise exception using errcode='P0001',message='extension_removed'; end if;
  if exists (select 1 from public.extension_operations where kind in ('install','update') and status='preparing'
    and catalog_id=v_install.catalog_id and publisher=v_install.publisher and name=v_install.name) then
    raise exception using errcode='P0001',message='extension_preparation_in_progress';
  end if;
  if v_install.revision <> p_expected_installation_revision then
    raise exception using errcode='P0001',message='extension_version_changed';
  end if;
  if v_install.previous_artifact_id is null then
    raise exception using errcode='P0001',message='extension_no_previous_version';
  end if;
  select * into v_target from public.extension_artifacts where id=v_install.previous_artifact_id;
  -- Desfazer tem a mesma regra: voltar a uma versão com outro conjunto de portas mudaria em
  -- silêncio o que a organização aceitou. Quem precisa disso reinstala e reativa.
  if v_target.manifest->'permissions' is distinct from
     (select manifest->'permissions' from public.extension_artifacts where id=v_install.artifact_id) then
    raise exception using errcode='P0001',message='extension_permissions_changed';
  end if;
  v_from := v_install;
  update public.extension_installations set artifact_id=previous_artifact_id, previous_artifact_id=artifact_id,
    version=v_target.manifest->>'version', revision=revision+1 where id=p_installation returning * into v_install;
  select count(*)::integer into v_active from public.organization_extensions where installation_id=p_installation and enabled;
  insert into public.extension_operations(id,kind,status,actor_id,catalog_id,installation_id,publisher,name,version,
    request,request_fingerprint,result)
    values(p_operation,'revert','completed',p_actor,v_install.catalog_id,v_install.id,v_install.publisher,v_install.name,
      v_install.version,v_request,public.fn_extensions_fingerprint(v_request),
      jsonb_build_object('installation',to_jsonb(v_install),'from_revision',v_from.revision,'from_artifact_id',v_from.artifact_id,
        'from_version',v_from.version,'to_artifact_id',v_install.artifact_id,'to_version',v_install.version,
        'organizations_active',v_active))
    returning * into v_op;
  return to_jsonb(v_op) || jsonb_build_object('applied_now', true);
end $$;

revoke execute on function public.fn_extensions_admit_catalog(uuid, uuid, jsonb, text) from public, anon;
revoke execute on function public.fn_extensions_admit_catalog(uuid, uuid, jsonb, text) from authenticated;
grant execute on function public.fn_extensions_admit_catalog(uuid, uuid, jsonb, text) to service_role;
revoke execute on function public.fn_extensions_finish_install(uuid, uuid, jsonb, text, integer, text) from public, anon;
revoke execute on function public.fn_extensions_finish_install(uuid, uuid, jsonb, text, integer, text) from authenticated;
grant execute on function public.fn_extensions_finish_install(uuid, uuid, jsonb, text, integer, text) to service_role;
revoke execute on function public.fn_extensions_revert_install(uuid, uuid, uuid, integer) from public, anon;
revoke execute on function public.fn_extensions_revert_install(uuid, uuid, uuid, integer) from authenticated;
grant execute on function public.fn_extensions_revert_install(uuid, uuid, uuid, integer) to service_role;

-- ---- marcadores do contato no filtro de conversas (migration 0323) ----
-- Campo calculado do PostgREST: o filtro ?tag= do Inbox casa conversations.tags
-- OU contacts.tags num único or=, sem lista de ids na URL. SECURITY INVOKER (a
-- RLS de contacts vale para quem chama); as duas origens de EXECUTE revogadas.
-- Antes da varredura de anon, como toda função nova do apêndice.
create or replace function public.tags_do_contato(c public.conversations)
  returns text[]
  language sql
  stable
  set search_path = public
as $$
  select ct.tags from public.contacts ct where ct.id = c.contact_id
$$;

comment on function public.tags_do_contato(public.conversations) is
  'Campo calculado do PostgREST: os marcadores do contato da conversa. Permite ao filtro ?tag= do Inbox casar conversations.tags OU contacts.tags num único or= (migration 0323).';

revoke execute on function public.tags_do_contato(public.conversations) from public, anon;
grant  execute on function public.tags_do_contato(public.conversations) to authenticated, service_role;

notify pgrst, 'reload schema';

-- ---- transporte SMTP da instalação: a segunda opção de e-mail (migration 0333) ----
--
-- Singleton de escopo de INSTALAÇÃO, no mesmo desenho de `platform_meta_app`
-- (0257) e `platform_google_oauth` (0201): um servidor SMTP atende os e-mails de
-- todas as empresas desta VPS. A Resend NÃO sai — `lib/email/roteador.ts` usa
-- SMTP quando há SMTP e Resend quando não há, e as sete `SMTP_*` do `.env`
-- seguem valendo como piso de rollback.
--
-- O `revoke` é obrigatório: o `alter default privileges` do topo deste arquivo
-- concede tabela nova a `anon` e `authenticated`.
--
-- Idempotente e auto-curativo (é o caminho do `update.sh` de um clone): tabela,
-- comentários e trigger com `if not exists`/`drop … if exists`. Nenhum dado é
-- tocado e nenhuma constraint nova incide sobre linha existente.
create table if not exists public.platform_smtp_settings (
  id smallint primary key default 1,
  smtp_host text,
  smtp_port integer not null default 587 check (smtp_port between 1 and 65535),
  smtp_security text not null default 'starttls' check (smtp_security in ('starttls', 'tls', 'none')),
  smtp_username text,
  smtp_password_encrypted bytea,
  from_email text,
  from_name text,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint platform_smtp_settings_singleton check (id = 1),
  constraint platform_smtp_settings_host check (smtp_host is null or smtp_host ~ '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$'),
  constraint platform_smtp_settings_from_email check (
    from_email is null or from_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  )
);

comment on table public.platform_smtp_settings is
  'O servidor SMTP DESTA INSTALAÇÃO (singleton). Server-side only: RLS ligada sem policies e grants revogados de anon/authenticated — o PostgREST não a serve. A senha é cifrada e nunca volta ao browser; a tela devolve apenas se existe.';
comment on column public.platform_smtp_settings.smtp_password_encrypted is
  'Cifrada por fn_encrypt_oauth (pgp_sym_encrypt/aes256). Nunca gravar em claro: sem a chave mestra o save recusa. Quem tem este valor manda e-mail como a instalação.';
comment on column public.platform_smtp_settings.smtp_security is
  'starttls (normalmente porta 587), tls (TLS implícito, normalmente 465) ou none. O CHECK existe porque o valor vira flag do transporte em lib/email/smtp.ts.';

alter table public.platform_smtp_settings enable row level security;
revoke all on public.platform_smtp_settings from anon, authenticated;
grant select, insert, update on public.platform_smtp_settings to service_role;

drop trigger if exists trg_platform_smtp_settings_updated_at on public.platform_smtp_settings;
create trigger trg_platform_smtp_settings_updated_at
  before update on public.platform_smtp_settings
  for each row execute function public.fn_set_updated_at();

-- ---- ai_agents.channel + phone_numbers (migration 0347) ----
-- ============================================================
-- 0347_modulo_voip — ai_agents.channel, phone_numbers, fn_resolve_inbound_number
--
-- RECOMPOSTA. Esta migration existiu no PR #677 como 0232_modulo_voip e foi
-- apagada por acidente no commit 97eed0955 (que unificou crm_calls em
-- voice_calls): o apêndice do baseline manteve o bloco, mas o arquivo sumiu,
-- e quem aplica as migrations em ordem nunca receberia phone_numbers.
-- O corpo abaixo é o bloco do apêndice, que já descartava crm_calls (ver
-- 0348_voice_calls_sip). Renumerada para acima do máximo da main.
-- ============================================================

--
-- SIP/Asterisk + IA de voz via OpenAI Realtime. Segue os mesmos padrões de
-- conversations/messages: RLS por tenant via fn_user_org_ids(), audit
-- append-only em mutações, text+CHECK (nunca enum nativo).
--
-- Sem event_log para call.*: nenhum handler em lib/event-log/register-handlers.ts
-- consumiria esses tipos ainda — evento sem handler nasce `pending` pra sempre
-- no drain (anti-pattern nº 3, ver migration 0155). Se um consumidor real
-- aparecer, adicionar handler + trigger juntos, não antes.

alter table public.ai_agents
  add column if not exists channel text not null default 'whatsapp';

alter table public.ai_agents
  drop constraint if exists ai_agents_channel_check;

alter table public.ai_agents
  add constraint ai_agents_channel_check
  check (channel = any (array['whatsapp', 'voice']));

create table if not exists public.phone_numbers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  number text not null unique,
  label text,

  trunk_endpoint text not null,
  routing_mode text not null default 'ai'
    check (routing_mode = any (array['ai', 'human', 'ai_then_human'])),
  default_ai_agent_id uuid references public.ai_agents(id) on delete set null,
  fallback_user_id uuid references auth.users(id) on delete set null,

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_phone_numbers_org on public.phone_numbers(organization_id);
create index if not exists idx_phone_numbers_active on public.phone_numbers(number) where is_active;

alter table public.phone_numbers enable row level security;

drop policy if exists phone_numbers_isolation on public.phone_numbers;
create policy phone_numbers_isolation on public.phone_numbers
  using (organization_id in (select fn_user_org_ids()))
  with check (organization_id in (select fn_user_org_ids()));

drop trigger if exists trg_phone_numbers_updated_at on public.phone_numbers;
create trigger trg_phone_numbers_updated_at
  before update on public.phone_numbers
  for each row execute function public.fn_set_updated_at();

drop trigger if exists trg_phone_numbers_audit on public.phone_numbers;
create trigger trg_phone_numbers_audit
  after insert or update or delete on public.phone_numbers
  for each row execute function public.fn_audit_log_row();

-- Resolve org + config de roteamento a partir do número discado (DNIS).
-- Usado pelo worker (service-role, ignora RLS).
create or replace function public.fn_resolve_inbound_number(p_number text)
returns table (
  organization_id uuid,
  routing_mode text,
  default_ai_agent_id uuid,
  fallback_user_id uuid
) as $$
  select organization_id, routing_mode, default_ai_agent_id, fallback_user_id
  from public.phone_numbers
  where number = p_number and is_active
  limit 1;
$$ language sql security definer stable;

-- Regra do item 9 do CLAUDE.md: função nova em public nasce exposta via as
-- DUAS origens (default privileges + grant implícito a PUBLIC). Revoga as
-- duas, concede só a service_role (é o worker quem chama, via admin client).
revoke execute on function public.fn_resolve_inbound_number(text) from public, anon;
grant execute on function public.fn_resolve_inbound_number(text) to service_role;

notify pgrst,'reload schema';

-- ---- voice_calls ganha o módulo SIP (migration 0348) ----
-- 0348_voice_calls_sip (nasceu 0252 no PR #677; renumerada)
--
-- Unifica `crm_calls` (nosso módulo SIP/AudioSocket, ainda não mergeado —
-- PR #677) dentro de `voice_calls` (WhatsApp/WaCalls, mergeada via #628/#697,
-- migrations 0233-0236). A própria triagem do #677 apontou o problema: duas
-- tabelas de chamada que não conversam — o histórico de uma ligação SIP não
-- aparecia junto do de uma ligação de WhatsApp na ficha do mesmo cliente.
--
-- `voice_calls` foi desenhada só pra WhatsApp: `channel_session_id`
-- (sessão pareada) e `wacalls_call_id` são `not null`, e o vocabulário de
-- `status` (`starting|ringing|connected|ended`) é literal do BINÁRIO WaCalls
-- upstream, não nosso — não se toca nisso (mesmo espírito do `end_reason`,
-- que a 0233 já deixa livre de propósito por ser vocabulário de terceiro).
--
-- O que este arquivo faz:
--   1. Relaxa as duas colunas WhatsApp-only pra nullable (SIP não tem sessão
--      pareada nem id do binário WaCalls).
--   2. Acrescenta `provider` (discriminador) + colunas SIP/IA, todas aditivas
--      e nullable — toda linha de WhatsApp existente fica com elas em null.
--   3. Migra as linhas de `crm_calls` (dados de teste do módulo SIP, ainda
--      não em produção real) pro novo formato e derruba a tabela antiga —
--      dentro do mesmo arquivo pra não deixar as duas tabelas concorrentes
--      vivas em nenhum commit.
--   4. Estende `fn_lgpd_cascade_redact_contact`: sem isto, anonimizar um
--      contato deixaria a TRANSCRIÇÃO da ligação (que pode conter o nome
--      dele, falado em voz) intacta, ligada ao `contact_id` — mesmo buraco
--      de reidentificação que a 0235 já fechou pra `peer_phone`.
--
-- Doutrina deste repo: migration não se edita depois de aplicada em algum
-- ambiente — o que se corrige, corrige-se pra frente. Tudo aqui é
-- idempotente (`if not exists`/`if exists`) pra rodar seguro num clone que
-- ainda não tem `crm_calls` (a tabela nunca chegou a ser mergeada em `main`)
-- e também num ambiente (esta VPS) onde ela já existe com dados de teste.

-- ─── 1. relaxa colunas WhatsApp-only ────────────────────────────────────────
alter table public.voice_calls alter column channel_session_id drop not null;
alter table public.voice_calls alter column wacalls_call_id drop not null;

-- ─── 2. colunas novas, aditivas ─────────────────────────────────────────────
alter table public.voice_calls
  add column if not exists provider text not null default 'wacalls',
  add column if not exists asterisk_channel_id text,
  add column if not exists lead_id uuid references public.crm_leads(id) on delete set null,
  add column if not exists ai_agent_id uuid references public.ai_agents(id) on delete set null,
  add column if not exists handled_by text,
  add column if not exists transcript jsonb,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table public.voice_calls drop constraint if exists voice_calls_provider_check;
alter table public.voice_calls
  add constraint voice_calls_provider_check
  check (provider = any (array['wacalls', 'sip']));

alter table public.voice_calls drop constraint if exists voice_calls_handled_by_check;
alter table public.voice_calls
  add constraint voice_calls_handled_by_check
  check (handled_by is null or handled_by = any (array['human', 'ai', 'ai_then_human']));

create index if not exists idx_voice_calls_asterisk_channel
  on public.voice_calls(asterisk_channel_id) where asterisk_channel_id is not null;
create index if not exists idx_voice_calls_lead
  on public.voice_calls(lead_id) where lead_id is not null;

comment on column public.voice_calls.provider is
  'Discrimina a origem da ligação: ''wacalls'' (WhatsApp, #628/#697) ou ''sip'' (Asterisk/AudioSocket, #677). Todo o resto do schema é compartilhado.';
comment on column public.voice_calls.status is
  'Vocabulário do provider ''wacalls'' (binário WaCalls upstream) reaproveitado por ''sip'': ringing=tocando, connected=atendida, ended=terminal (granularidade extra em end_reason). Ver mapeamento no worker (lib/voip).';

-- ─── 3. migra dados de crm_calls (se existir) e derruba a tabela antiga ────
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'crm_calls') then

    insert into public.voice_calls (
      id, organization_id, contact_id, lead_id, provider, direction, status,
      end_reason, peer_phone, asterisk_channel_id, ai_agent_id, handled_by,
      transcript, metadata, started_at, answered_at, ended_at, duration_ms,
      created_by, created_at, updated_at
    )
    select
      c.id, c.organization_id, c.contact_id, c.lead_id, 'sip', c.direction,
      case c.status
        when 'ringing' then 'ringing'
        when 'in_progress' then 'connected'
        else 'ended'
      end,
      case c.status
        when 'no_answer' then 'timeout'
        when 'busy' then 'busy'
        when 'failed' then 'failed'
        when 'canceled' then 'cancelled'
        when 'completed' then 'user_ended'
        else null
      end,
      case c.direction when 'outbound' then c.to_number else c.from_number end,
      c.asterisk_channel_id, c.ai_agent_id, c.handled_by, c.transcript,
      coalesce(c.metadata, '{}'::jsonb), c.started_at, c.answered_at,
      c.ended_at, c.duration_seconds * 1000, c.assigned_to_user_id,
      c.created_at, c.updated_at
    from public.crm_calls c
    on conflict (id) do nothing;

    drop table public.crm_calls;
  end if;
end $$;

-- ─── 4. LGPD: a transcrição entra na cascata de redação ────────────────────
-- (redefine a function inteira — mesmo padrão da 0235, que já fez isto pra
-- acrescentar o bloco de voice_calls original; aqui só o UPDATE de
-- voice_calls ganha `transcript = null` a mais. O corpo é a definição
-- VIGENTE da main no momento da renumeração, e não a de quando este PR
-- nasceu: redefinir a partir de uma cópia velha desfaria em silêncio o que
-- a main consertou na cascata desde então.)
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
  perform public.fn_service_lock(p_organization_id,p_contact_id);
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
    -- O motivo CRU da última passagem (migration 0291). É código de
    -- vocabulário, não texto livre — mas ele diz que ESTA pessoa foi escalada
    -- por irritação, por assunto jurídico ou por suspeita de opt-out, e isso é
    -- um fato sobre ela. Entra NESTE update, e não num segundo: mesmo
    -- predicado, mesmas linhas, metade das varreduras.
    --
    -- ⚠️ `last_handoff_reason` é CHAVE DE NEGÓCIO em outro módulo: a ponte de
    -- voz limpa o silêncio filtrando pelo VALOR da coluna
    -- (`lib/wacalls/events-bridge.ts`). Zerá-la num contato anonimizado é
    -- seguro — não há chamada viva de contato anonimizado — e é a razão de
    -- esta entrega NÃO usar essa coluna para texto rico: ela continua
    -- recebendo só o código, e o texto vive em `passagens_de_atendimento`.
    last_handoff_reason = null,
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

  -- 7b. voice_calls — o TELEFONE de quem falou ao telefone (migration 0235).
  --
  -- `peer_phone` é `not null` e guarda o número da outra ponta: depois de
  -- anonimizar o contato, ele sobrevivia ligado ao `contact_id` e reidentificava
  -- a pessoa que pediu para ser esquecida. É o mesmo argumento que a foto de
  -- perfil já tinha (ver o bloco do avatar em `lib/lgpd/redact-cascade.ts`):
  -- anonimizar em toda parte menos numa é não ter anonimizado.
  --
  -- O que fica: direção, status, motivo do fim, marcas de tempo e duração. Um
  -- registro de "houve uma chamada de 12 minutos" sem número e sem dono não
  -- identifica ninguém e é o que sustenta a métrica do atendente e a fatura.
  -- `peer_phone` é NOT NULL, então recebe o rótulo, não `null`.
  update voice_calls set
    transcript = null,
    peer_phone = v_anon_label,
    owner_user_id = null,
    created_by = null,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('voice_calls', v_count);

  -- agent_cases — o que a IA escreveu SOBRE a pessoa quando travou (migration 0280).
  --
  -- O caso é o texto que a equipe lê antes de decidir: `title`, `summary` e
  -- `blocker` saem do modelo a partir da conversa, e `context_snapshot` é o
  -- recorte dessa conversa que o motor mandou para ele. Nada disso é registro de
  -- operação — é o relato do problema de uma pessoa identificável, escrito por
  -- máquina. Sem este passo, anonimizar devolvia SUCESSO com o relato intacto.
  --
  -- As três colunas de texto são `not null`: recebem rótulo e texto fixo, nunca
  -- `null` (a mesma razão de `voice_calls.peer_phone` logo acima).
  --
  -- ⚠️ `updated_at` FICA FORA DO `set`, de propósito. O cobrador de caso parado
  -- (`app/api/v1/cron/case-stale-watcher/route.ts`) lê `updated_at` como "alguém
  -- da equipe encostou neste caso". A cascata não é alguém encostando: escrever
  -- ali faria a anonimização ADIAR a cobrança de um caso que continua parado, e
  -- o efeito só apareceria como um cliente esperando mais tempo.
  --
  -- O vínculo é pela CONVERSA porque `agent_cases` não tem FK para `contacts`.
  update agent_cases set
    title = v_anon_label,
    summary = '[resumo anonimizado]',
    blocker = '[bloqueio anonimizado]',
    context_snapshot = '{}'::jsonb
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_cases', v_count);

  -- agent_case_events — a linha do tempo do caso (migration 0280).
  --
  -- `body` é o que a pessoa da equipe escreveu ao responder o caso e o que o
  -- agente registrou sobre o que o LEAD respondeu; `metadata` carrega o recorte
  -- que o motor anexou. `kind`, `actor_kind`, `human_action` e `created_at`
  -- FICAM: são o registro de que houve um toque humano e quando — operação, não
  -- dado da pessoa, e é deles que sai a métrica de atendimento.
  update agent_case_events set
    body = null,
    metadata = '{}'::jsonb
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_events', v_count);

  -- demandas — o assunto do pedido (migration 0280).
  --
  -- `assunto` é texto livre sobre o que a pessoa pediu. O resto da linha é a
  -- operação da demanda (origem, estado, dono, prazo, desfecho) e fica de pé:
  -- apagar a linha inteira tiraria da organização a resposta a "quantos pedidos
  -- houve em março", que é o mesmo argumento do compromisso da agenda.
  --
  -- FK direta (`demandas.contact_id` é `not null`), então o vínculo é o contato.
  update demandas set
    assunto = null
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('demandas', v_count);

  -- agent_inbox_items — o aviso que leva o texto do caso para a Central (migration 0280).
  --
  -- O `body` do aviso de caso parado EMBUTE o título do caso
  -- (`app/api/v1/cron/case-stale-watcher/route.ts:128`), e o do handoff embute o
  -- motivo da parada (`lib/ai/handoff/orchestrator.ts:335`). Redigir o caso e
  -- deixar o aviso de pé seria anonimizar em toda parte menos numa — que é não
  -- ter anonimizado. O molde (resolver + trocar o corpo + soltar a referência) é
  -- o de `fn_meet_redact_contact`, que já faz isto para o aviso de compromisso.
  --
  -- ⚠️ O VÍNCULO É POLIMÓRFICO E TEM TRÊS BRAÇOS, não dois. Medido nos
  -- produtores, não suposto: `handoff` nasce com `ref_kind='contact'`
  -- (`lib/ai/handoff/orchestrator.ts:339`) E com `ref_kind='conversation'`
  -- (`lib/agent-engine/agent/inbound-turn.ts:4100`); `case_stale` nasce SEMPRE
  -- com `ref_kind='agent_case'` (a rota do cron acima, e a política em
  -- `lib/ai/inbox-destino.ts:38`). Um predicado com só os dois primeiros braços
  -- casa ZERO avisos de caso parado — e casar zero linha não é erro: é sucesso
  -- com o texto intacto.
  --
  -- Os `kind` são os MEDIDOS no CHECK vigente (`supabase/baseline.sql`, bloco
  -- único de `agent_inbox_items_kind_check`). `case_opened` NÃO existe, e kind
  -- inexistente num `in (...)` também casa zero e devolve sucesso. Para
  -- reconferir sem acreditar nesta prosa:
  --   grep -n "agent_inbox_items_kind_check check" -A40 supabase/baseline.sql
  update agent_inbox_items set
    status = 'resolved',
    resolved_at = now(),
    body = 'Contato anonimizado.',
    ref_id = null
  where organization_id = p_organization_id
    -- `aviso_de_caso_nao_entregue` (migration 0292) entra AQUI e não num
    -- passo próprio: é o mesmo predicado polimórfico, e o braço
    -- `ref_kind='agent_case'` já alcança o caso do titular. O corpo do aviso
    -- embute o título do caso, que é texto sobre a pessoa.
    and kind in ('handoff', 'case_stale', 'aviso_de_caso_nao_entregue')
    and (
      (ref_kind = 'contact' and ref_id = p_contact_id)
      or (ref_kind = 'conversation' and ref_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          ))
      or (ref_kind = 'agent_case' and ref_id in (
            select id from agent_cases
              where organization_id = p_organization_id
                and conversation_id in (
                  select id from conversations
                    where contact_id = p_contact_id and organization_id = p_organization_id
                )
          ))
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_inbox_items', v_count);

  -- agent_case_chat_messages — a consulta interna da equipe à IA SOBRE o caso
  -- (migration 0281). FK DIRETA para `contacts`, então o vínculo é o titular e
  -- não precisa passar pela conversa.
  --
  -- `redacted_at is null` no `where` é o que torna o passo IDEMPOTENTE: a
  -- varredura diária de redações incompletas roda a função de novo, e sem essa
  -- condição o carimbo de QUANDO se apagou seria reescrito a cada rodada.
  --
  -- A linha NÃO é apagada, só o texto: quem abrir o caso depois continua vendo
  -- que a equipe perguntou N vezes, quando, e se a IA respondeu. Apagar a linha
  -- inteira ficaria verde num teste de "o texto sumiu" e tiraria da organização
  -- a resposta a "quanto a equipe deliberou sobre este caso".
  update agent_case_chat_messages set
    body = null,
    redacted_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id
    and redacted_at is null;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_chat_messages', v_count);

  -- passagens_de_atendimento — o BRIEFING é sobre a pessoa (migration 0291).
  --
  -- A linha guarda o que a IA concluiu sobre um atendimento de alguém
  -- identificável: o que ela entendeu que a pessoa quer (`title`), a narrativa
  -- que quem assumiu leu (`body`), as PALAVRAS LITERAIS do cliente (`notes`), o
  -- texto livre de quem passou (`content`) e o que a IA já tinha tentado
  -- (`tentativas`). Nada disso é registro de operação — é o relato do problema
  -- de uma pessoa, escrito por máquina, na tela de quem vai responder.
  --
  -- `body` é `not null` e recebe o RÓTULO, não `null` — a mesma razão de
  -- `voice_calls.peer_phone` e de `agent_cases.title` acima: coluna obrigatória
  -- anulada aborta o cascade INTEIRO, e um cascade abortado não anonimiza nada.
  --
  -- O que FICA, de propósito: `motor`, `origem`, `motivo_codigo`,
  -- `cliente_avisado`, `aviso_motivo_codigo`, `criado_em` e o par de
  -- reconhecimento. São operação — quantas passagens houve, por quê, quanto
  -- tempo até alguém assumir. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos atendimentos a IA devolveu em março, e quanto tempo esperaram".
  --
  -- O vínculo é a FK DIRETA `contact_id`: a tabela a carrega exatamente para
  -- este passo não precisar passar pela conversa.
  update passagens_de_atendimento set
    body       = v_anon_label,
    title      = null,
    notes      = null,
    content    = null,
    tentativas = '[]'::jsonb
  where organization_id = p_organization_id and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('passagens_de_atendimento', v_count);

  -- entregas_de_aviso_de_caso — o registro do aviso ao suporte (migration 0292).
  --
  -- A tabela NÃO guarda o texto do aviso (só `corpo_hash`), e a única coluna
  -- capaz de ecoar um dado da pessoa é `erro_detalhe`: ali vai o texto CRU que
  -- o transporte devolveu, truncado, e um provedor que recusa um envio costuma
  -- devolver o destinatário dentro da mensagem de erro.
  --
  -- O que FICA, de propósito: `status`, `erro_codigo`, `tentativas`,
  -- `enviado_em`, `destino`, `corpo_hash`. São operação — quantos avisos saíram,
  -- quantos falharam e por quê. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos avisos não chegaram em março". `destino` é o telefone da EQUIPE,
  -- não do titular: anonimizar um cliente não apaga o número do plantão.
  --
  -- ⚠️ PONTO CEGO DECLARADO: `tests/invariants/lgpd-cascata-alcanca-quem-
  -- guarda-pessoa.test.ts` só cobra tabela com FK para `contacts` E coluna cujo
  -- NOME case o padrão de PII. Esta tabela não satisfaz nenhuma das duas — o
  -- gate ficaria VERDE sem este passo. Ele entra porque é certo, não porque o
  -- gate cobra, e isto está escrito aqui para a próxima sessão não o remover
  -- achando que é ornamento. Quem o vigia é a catraca
  -- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
  --
  -- O vínculo é pela CONVERSA, como o de `agent_cases`: esta tabela aponta para
  -- o caso, e o caso não tem FK para `contacts`.
  update entregas_de_aviso_de_caso set
    erro_detalhe = null
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('entregas_de_aviso_de_caso', v_count);

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

-- ---- voip_trunk_settings (migration 0349) ----
-- 0349_voip_trunk_settings (nasceu 0257 no PR #677; renumerada)
--
-- Tela de configuração de trunk SIP por organização — hoje o único trunk do
-- módulo de voz (Asterisk/AudioSocket, #677) vive hardcoded em
-- `asterisk/pjsip.conf`, um arquivo na VPS, fora do banco. Decisão: um trunk
-- por organização, configurável numa tela (Configurações > Trunk SIP).
--
-- Aplicar no Asterisk continua MANUAL por enquanto (decisão explícita) —
-- esta tabela só guarda e exibe; não há reload automático de `pjsip.conf`
-- nesta fase. `organization_id` é a CHAVE PRIMÁRIA (mesmo padrão de
-- `org_voice_calls`/`org_guardrail_layers`): é config de UM trunk por
-- organização, não uma lista.
--
-- Senha cifrada com o MESMO esquema AES-256-GCM de `ai_provider_credentials`
-- (`lib/crypto/aes_gcm.ts`, chave `AI_CRED_AES_KEY`) — nunca plaintext em
-- disco. Só `password_last4` é exposto pela view segura
-- (`voip_trunk_settings_safe`), mesmo padrão de `api_key_last4`.

create table if not exists public.voip_trunk_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  host text not null,
  port integer not null default 5060,
  username text not null,
  password_encrypted bytea not null,
  password_iv bytea not null,
  password_tag bytea not null,
  password_last4 text not null,
  from_domain text,
  endpoint_name text not null,
  is_active boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.voip_trunk_settings enable row level security;

-- Leitura: qualquer membro da org (a tela de originar chamada precisa saber
-- SE existe trunk configurado). Escrita: só admin — são credenciais de um
-- provedor SIP real, o mesmo nível de sensibilidade de ai_provider_credentials.
drop policy if exists voip_trunk_settings_select on public.voip_trunk_settings;
create policy voip_trunk_settings_select on public.voip_trunk_settings
  for select using (organization_id in (select public.fn_user_org_ids()));

drop policy if exists voip_trunk_settings_admin_write on public.voip_trunk_settings;
create policy voip_trunk_settings_admin_write on public.voip_trunk_settings
  for all
  using (
    organization_id in (select public.fn_user_org_ids())
    and public.fn_role_at_least(organization_id, 'admin')
  )
  with check (
    organization_id in (select public.fn_user_org_ids())
    and public.fn_role_at_least(organization_id, 'admin')
  );

-- A anon key vai para o browser — sem isto, o GRANT ALL ON TABLES TO anon do
-- baseline (que vale pra toda tabela nova) deixaria a tabela alcançável sem
-- sessão nenhuma, RLS ou não.
revoke all on public.voip_trunk_settings from anon;

drop trigger if exists trg_voip_trunk_settings_set_updated_at on public.voip_trunk_settings;
create trigger trg_voip_trunk_settings_set_updated_at
  before update on public.voip_trunk_settings
  for each row execute function public.fn_set_updated_at();

-- View segura: NUNCA expõe password_encrypted/iv/tag — mesmo padrão de
-- ai_provider_credentials_safe. security_invoker=true: a view roda com o
-- privilégio de quem CONSULTA, então a RLS da tabela base (acima) se aplica
-- através dela também — sem isto, uma view SECURITY DEFINER furaria o RLS.
create or replace view public.voip_trunk_settings_safe
  with (security_invoker = true) as
select
  organization_id, host, port, username, password_last4, from_domain,
  endpoint_name, is_active, updated_by, created_at, updated_at
from public.voip_trunk_settings;

revoke all on public.voip_trunk_settings_safe from anon;
grant select on public.voip_trunk_settings_safe to authenticated;

notify pgrst, 'reload schema';

-- ---- módulo instalado: instalar e reaplicar, D3 e D6 da ADR-0002 (migration 0340) ----
--
-- Cópia literal da migration, com duas diferenças: as duas chamadas do fim moram
-- no rodapé do arquivo, depois de toda tabela; e a CHECK de `kind` ampliada vive no
-- bloco único dela (0271). Entra ANTES da VARREDURA anon porque cria função.
-- 0340 — Módulo instalado: D3 e D6 da ADR-0002 (onda 2, issue #1114)
--
-- Empilhada sobre a 0325 (#1178, onda 1): chama as provisionadoras, que terminam em
-- `fn_proteger_modulo_provisionado()`. Por isso vem DEPOIS dela no timestamp — posição de
-- migration aqui é semântica, não cosmética.
--
-- D3 — instalar um módulo na INSTÂNCIA cria as tabelas dele na hora. O corte é por instalação,
-- não por organização (decisão do dono, aceite da ADR-0002).
-- D6 — reaplicar nas atualizações é explícito e falha alto.
--
-- O QUE NÃO ESTÁ AQUI: a provisionadora de um módulo concreto. Nenhum módulo com tabelas está na
-- main; o primeiro (financeiro/comanda) escreve o próprio corpo. Até lá, a lista de módulos
-- instaláveis é VAZIA em todo banco de cliente, e o mecanismo é provado por um módulo de teste
-- que só existe na bateria de invariantes.
--
-- Desenho completo: docs/specs/modulo-instalado-onda-2.md.

-- ── 1. O registro da instância ───────────────────────────────────────────────
create table if not exists public.modulos_instalados (
  modulo text primary key check (modulo ~ '^[a-z][a-z0-9_]{1,40}$'),
  estado text not null default 'ativo' check (estado in ('ativo', 'suspenso')),
  instalado_em timestamptz not null default now(),
  instalado_por uuid references auth.users(id) on delete set null,
  reaplicado_em timestamptz,
  motivo_suspensao text
);
comment on table public.modulos_instalados is
  'Módulos opcionais instalados NA INSTÂNCIA (ADR-0002, D3). Sem organization_id: o corte é por instalação. Escrito só por fn_modulo_instalar e fn_reaplicar_modulos_instalados.';

alter table public.modulos_instalados enable row level security;
revoke all on public.modulos_instalados from anon, authenticated;

-- ── 2. O recibo mora no mesmo livro das extensões ────────────────────────────
-- Um tipo novo, `module_install`, em vez de um segundo livro: a instalação passa "pelo mesmo
-- caminho já provado das extensões" (ADR-0002, D3) — chave idempotente, `applied_now`, e a tela
-- de recibos que já existe. É recibo de PLATAFORMA (organization_id nulo), o que a restrição de
-- escopo já aceita sem mudança.
-- A lista ampliada com `module_install` NÃO é recriada aqui: ela vive no bloco único da
-- constraint, no apêndice da migration 0271 — uma constraint, um bloco
-- (tests/unit/baseline-constraint-reconstruida.test.ts). A migration 0340 faz o drop + add.

-- ── 3. A porta de instalação ─────────────────────────────────────────────────
create or replace function public.fn_modulo_instalar(p_actor uuid, p_operation uuid, p_modulo text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_request jsonb := jsonb_build_object('kind', 'module_install', 'actor', p_actor, 'modulo', p_modulo);
  v_op public.extension_operations;
begin
  perform public.fn_extensions_assert_actor(p_actor);
  if p_operation is null or p_modulo is null or p_modulo !~ '^[a-z][a-z0-9_]{1,40}$' then
    raise exception using errcode = 'P0001', message = 'extension_invalid_input';
  end if;

  -- A mesma trava das extensões: serializa com instalar/atualizar pacote E com a atualização do
  -- núcleo. O ator é conferido de novo depois dela, porque a autoridade pode ter mudado na espera.
  perform pg_advisory_xact_lock(255, 1);
  perform public.fn_extensions_assert_actor(p_actor);

  select * into v_op from public.extension_operations where id = p_operation;
  if found then
    if v_op.request_fingerprint <> public.fn_extensions_fingerprint(v_request) then
      raise exception using errcode = 'P0001', message = 'extension_idempotency_conflict';
    end if;
    return to_jsonb(v_op) || jsonb_build_object('applied_now', false);
  end if;

  -- A lista de módulos instaláveis é o conjunto de provisionadoras que EXISTEM. Não há segunda
  -- lista para divergir: um módulo oficial entra pela tripla migration + baseline + MANIFEST
  -- trazendo `fn_<modulo>_provisionar()`, e o invariante da onda 1 prova a forma dela.
  if to_regprocedure(format('public.fn_%s_provisionar()', p_modulo)) is null then
    raise exception using errcode = 'P0001', message = 'extension_module_unknown';
  end if;

  if public.fn_extensions_core_update_in_progress() then
    raise exception using errcode = 'P0001', message = 'extension_core_update_in_progress';
  end if;

  -- O nome só chega aqui depois de passar pelo slug e pela existência da função; `%I` o cita.
  execute format('select public.%I()', 'fn_' || p_modulo || '_provisionar');

  insert into public.modulos_instalados (modulo, estado, instalado_por, reaplicado_em)
    values (p_modulo, 'ativo', p_actor, now())
    on conflict (modulo) do update
      set estado = 'ativo', motivo_suspensao = null, reaplicado_em = now();

  insert into public.extension_operations
      (id, kind, status, actor_id, name, request_fingerprint, request, result)
    values
      (p_operation, 'module_install', 'completed', p_actor, p_modulo,
       public.fn_extensions_fingerprint(v_request), v_request, jsonb_build_object('modulo', p_modulo))
    returning * into v_op;

  -- Tabela criada em tempo de execução é INVISÍVEL para a API até o PostgREST recarregar o
  -- schema. Sem isto, "instalar e usar, sem espera" (condição 3 do dono) seria falso: o módulo
  -- estaria instalado e o app receberia 404 ao consultá-lo. A notificação sai no commit.
  perform pg_notify('pgrst', 'reload schema');

  return to_jsonb(v_op) || jsonb_build_object('applied_now', true);
end $$;

revoke execute on function public.fn_modulo_instalar(uuid, uuid, text) from public, anon;
revoke execute on function public.fn_modulo_instalar(uuid, uuid, text) from authenticated;
grant execute on function public.fn_modulo_instalar(uuid, uuid, text) to service_role;

-- ── 4. A reaplicação nas atualizações (D6) — dois comandos, de propósito ─────
-- O kit aplica o baseline SEM transação única (`psql -f`) e trata como falha toda linha ERROR
-- que não case com a lista de benignos (`already exists` e afins, em _common.sh). Então:
--   A) captura a falha de cada módulo e o marca `suspenso` SEM relançar — o comando se confirma
--      sozinho e a marca PERSISTE;
--   B) se há módulo suspenso, levanta um ERROR com texto próprio, que o update.sh já reporta.
-- Num comando só, relançar desfaria a marca; não relançar deixaria o kit dizer "atualizado".
create or replace function public.fn_reaplicar_modulos_instalados()
returns void language plpgsql set search_path = public, pg_temp as $$
declare
  r record;
begin
  for r in select modulo from public.modulos_instalados order by modulo loop
    begin
      if to_regprocedure(format('public.fn_%s_provisionar()', r.modulo)) is null then
        raise exception 'a provisionadora de % não existe nesta versão', r.modulo;
      end if;
      execute format('select public.%I()', 'fn_' || r.modulo || '_provisionar');
      update public.modulos_instalados
        set estado = 'ativo', motivo_suspensao = null, reaplicado_em = now()
        where modulo = r.modulo;
    exception
      -- Disputa de trava com o app no ar NÃO é defeito do módulo: relançar desfaz esta
      -- passada inteira (nenhum módulo é marcado), e o texto do Postgres — "deadlock
      -- detected", "could not obtain lock" — é o que o kit reconhece como disputa e o faz
      -- aplicar de novo. Suspender aqui tiraria do ar um módulo que só precisava esperar.
      when deadlock_detected or serialization_failure or lock_not_available then
        raise;
      when others then
        update public.modulos_instalados
          set estado = 'suspenso', motivo_suspensao = sqlerrm
          where modulo = r.modulo;
    end;
  end loop;
  perform pg_notify('pgrst', 'reload schema');
end $$;

create or replace function public.fn_conferir_modulos_instalados()
returns void language plpgsql set search_path = public, pg_temp as $$
declare
  v_suspensos text;
begin
  select string_agg(modulo, ', ' order by modulo) into v_suspensos
    from public.modulos_instalados where estado = 'suspenso';
  -- A mensagem NÃO repete o erro original, e isso é o ponto: se a provisionadora falhou com
  -- "already exists" e o texto viesse junto, a linha casaria com a lista de erros benignos do
  -- kit e seria ENGOLIDA — exatamente o silêncio que esta função existe para impedir. O motivo
  -- fica em modulos_instalados.motivo_suspensao; o aviso só nomeia o módulo.
  if v_suspensos is not null then
    raise exception 'modulo suspenso na atualizacao: % — o motivo esta em modulos_instalados.motivo_suspensao', v_suspensos;
  end if;
end $$;

revoke execute on function public.fn_reaplicar_modulos_instalados() from public, anon, authenticated, service_role;
revoke execute on function public.fn_conferir_modulos_instalados() from public, anon, authenticated, service_role;

-- ---- a agenda dos colegas é uma opção da organização (migration 0343) ----
--
-- A opção "Atendentes podem mexer na agenda dos colegas" (issue #978), LIGADA
-- por padrão: `settings.colegas_podem_mexer_na_agenda` ausente = ligada, e só o
-- booleano `false` explícito desliga. Com ela desligada, o Atendente só mexe no
-- compromisso de que é dono; Gerente e Administrador seguem mexendo em tudo.
--
-- Chave PRÓPRIA de topo, e não `settings.agenda`: `fn_agenda_settings` substitui
-- o objeto inteiro e recusa chave que não conheça (o mesmo motivo que levou
-- `cliente_pela_agenda` para `settings.crm` na 0262). Sem backfill: nenhuma
-- linha de `organizations` é reescrita e quem já instalou não vê mudança.
--
-- O núcleo abaixo é a definição em vigor com UM bloco novo (a checagem de dono).
-- A explicação completa, e para quem a regra vale (pessoa / IA e integração /
-- canal remoto), está no cabeçalho de
-- `supabase/migrations/20260919160431_0343_agenda_dos_colegas.sql`.
create or replace function public.fn_colegas_podem_mexer_na_agenda(p_org uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(
   (select (o.settings->'colegas_podem_mexer_na_agenda') is distinct from 'false'::jsonb
      from public.organizations o where o.id = p_org),
   true);
$$;

revoke all on function public.fn_colegas_podem_mexer_na_agenda(uuid) from public,anon;
grant execute on function public.fn_colegas_podem_mexer_na_agenda(uuid) to authenticated,service_role;

comment on function public.fn_colegas_podem_mexer_na_agenda(uuid) is
  'A opção "Atendentes podem mexer na agenda dos colegas" desta organização (issue #978). Ausente = ligada: só o booleano false explícito em settings.colegas_podem_mexer_na_agenda desliga.';

create or replace function public.fn_appointment_change_core(p_org uuid,p_id uuid,p_revision bigint,p_patch jsonb,p_remote boolean,p_base jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.calendar_appointments; contact uuid; origin jsonb; event_id uuid;
begin
 if p_remote and (auth.uid() is not null or (p_patch-'starts_at'-'ends_at'-'time_zone'-'status'-'cancellation_reason')<>'{}'::jsonb or coalesce(p_patch->>'status','cancelled')<>'cancelled') then raise exception 'google_patch_forbidden' using errcode='42501';end if;
 if auth.uid() is not null and (not public.fn_role_at_least(p_org,'agent') or not public.fn_support_write_allowed(p_org)) then raise exception 'appointment_forbidden' using errcode='42501'; end if;
 if auth.uid() is not null and not public.fn_session_mfa_proven() then raise exception 'appointment_mfa_required' using errcode='42501';end if;
 select contact_id into contact from public.calendar_appointments where organization_id=p_org and id=p_id;
 if not found then raise exception 'appointment_not_found' using errcode='P0002'; end if;
 if contact is not null then perform public.fn_service_lock(p_org,contact); end if;
 select * into a from public.calendar_appointments where organization_id=p_org and id=p_id for update;
 if a.contact_id is distinct from contact or a.revision is distinct from p_revision then raise exception 'appointment_stale' using errcode='40001'; end if;
 -- A AGENDA DO COLEGA É UMA OPÇÃO DA ORGANIZAÇÃO (migration 0343, issue #978).
 if auth.uid() is not null and not public.fn_role_at_least(p_org,'manager')
    and not public.fn_colegas_podem_mexer_na_agenda(p_org)
    and a.owner_user_id is distinct from auth.uid() then
  raise exception 'appointment_do_colega' using errcode='42501';
 end if;
 if p_remote and a.status not in ('pending','confirmed') then raise exception 'google_outcome_protected' using errcode='40001';end if;
 if a.status='cancelled' then raise exception 'appointment_cancelled' using errcode='22023'; end if;
 if contact is not null then origin:=jsonb_build_object('kind','command','observed',public.fn_service_observe_command(p_org,contact)); end if;
 update public.calendar_appointments set
  google_base_projection=case when p_remote then p_base else google_base_projection end,
  starts_at=case when p_patch?'starts_at' then (p_patch->>'starts_at')::timestamptz else starts_at end,
  ends_at=case when p_patch?'ends_at' then (p_patch->>'ends_at')::timestamptz else ends_at end,
  time_zone=coalesce(p_patch->>'time_zone',time_zone),
  status=coalesce(p_patch->>'status',status),
  cancelled_at=case when p_patch->>'status'='cancelled' then now() else cancelled_at end,
  cancellation_reason=case when p_patch?'cancellation_reason' then p_patch->>'cancellation_reason' else cancellation_reason end,
  notes=case when p_patch?'notes' then p_patch->>'notes' else notes end,
  guest_email=case when p_patch?'guest_email' then p_patch->>'guest_email' else guest_email end,
  outcome_message_id=case when p_patch?'outcome_message_id' then (p_patch->>'outcome_message_id')::uuid else null end,
  confirmation_next_at=case when p_patch?'confirmation_next_at' then (p_patch->>'confirmation_next_at')::timestamptz else confirmation_next_at end
 where organization_id=p_org and id=p_id returning * into a;
 if p_patch?'confirmation_next_at' and (a.confirmation_next_at<=now() or a.confirmation_next_at>now()+interval '24 hours') then raise exception 'appointment_invalid_snooze' using errcode='22023'; end if;
 update public.followup_enrollments set status='cancelled',cancel_reason='O compromisso mudou. Revise o próximo passo.',completed_at=now(),next_eval_at=null,claimed_until=null
  where organization_id=p_org and appointment_id=p_id and appointment_revision<>a.revision and status in ('active','waiting_reply','paused_handoff','paused_manual');
 update public.agent_inbox_items set status='resolved',resolved_at=now()
  where organization_id=p_org and ref_kind='appointment' and ref_id=p_id and status='open'
   and (appointment_revision<>a.revision or a.status in ('completed','no_show','cancelled') or p_patch?'confirmation_next_at');
 if contact is not null and a.status='no_show' and a.outcome_recorded_at is not null and a.revision<>p_revision then
  insert into public.event_log(organization_id,event_type,entity_kind,entity_id,payload)
   values(p_org,'appointment.outcome_confirmed','appointment',p_id,
    jsonb_build_object('appointment_revision',a.revision,'service_origin',origin)) returning id into event_id;
 end if;
 return to_jsonb(a);
end; $$;

revoke all on function public.fn_appointment_change_core(uuid,uuid,bigint,jsonb,boolean,jsonb) from public,anon,authenticated;

create or replace function public.fn_definir_colegas_podem_mexer_na_agenda(p_org uuid,p_ligado boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_atual boolean; v_linhas int;
begin
 if p_ligado is null then raise exception 'agenda_dos_colegas_invalido' using errcode='22023'; end if;
 if auth.uid() is null
    or not public.fn_role_at_least(p_org,'manager')
    or not public.fn_support_write_allowed(p_org) then
  raise exception 'agenda_dos_colegas_forbidden' using errcode='42501';
 end if;
 if not public.fn_session_mfa_proven() then raise exception 'mfa_required' using errcode='42501'; end if;
 v_atual := public.fn_colegas_podem_mexer_na_agenda(p_org);
 if v_atual is not distinct from p_ligado then
  return jsonb_build_object('ligado',v_atual,'mudou',false);
 end if;
 update public.organizations
    set settings = coalesce(settings,'{}'::jsonb) || jsonb_build_object('colegas_podem_mexer_na_agenda',to_jsonb(p_ligado))
  where id = p_org;
 get diagnostics v_linhas = row_count;
 if v_linhas = 0 then raise exception 'agenda_dos_colegas_sem_organizacao' using errcode='P0002'; end if;
 return jsonb_build_object('ligado',p_ligado,'mudou',true);
end; $$;

revoke all on function public.fn_definir_colegas_podem_mexer_na_agenda(uuid,boolean) from public,anon;
grant execute on function public.fn_definir_colegas_podem_mexer_na_agenda(uuid,boolean) to authenticated,service_role;

comment on function public.fn_definir_colegas_podem_mexer_na_agenda(uuid,boolean) is
  'Liga/desliga "Atendentes podem mexer na agenda dos colegas" (issue #978). Gerente ou acima, suporte de escrita e MFA comprovado; ela mesma confere pelo auth.uid(). Grava settings.colegas_podem_mexer_na_agenda e devolve {ligado,mudou}.';

notify pgrst, 'reload schema';

-- ---- catálogo financeiro: contas, formas de pagamento, plano de contas (migration 0350) ----
-- O CATÁLOGO FINANCEIRO — a primeira camada do módulo de comanda/financeiro.
--
-- Três tabelas que não guardam dinheiro, só definem PARA ONDE ele vai:
--
--   financial_accounts  onde o dinheiro fica (Caixa, Banco)
--   payment_methods     como o cliente paga — e cada forma APONTA para a conta
--                       em que aquele dinheiro cai
--   account_plans       a classificação contábil do lançamento
--
-- A ordem importa: a forma de pagamento é quem decide em qual conta a entrada
-- é lançada quando uma comanda é finalizada. Sem esta camada, a comanda não tem
-- onde depositar, e é por isso que ela vem primeiro.
--
-- ⚠️ NADA AQUI TEM SALDO GRAVADO. `opening_balance_cents` é o saldo INICIAL —
-- o ponto de partida declarado por quem cadastrou a conta, que não muda com
-- lançamento nenhum. O saldo corrente é sempre DERIVADO por soma, e essa é uma
-- das invariantes do modelo: saldo gravado e lançamentos divergem no primeiro
-- estorno, e a divergência não dá sinal.
--
-- ⚠️ DINHEIRO EM `_cents` + `currency`, como manda o CLAUDE.md. Nunca `numeric`
-- solto: arredondamento de ponto flutuante em dinheiro é defeito que aparece
-- meses depois, num relatório que não fecha por centavos.

-- ─── onde o dinheiro fica ────────────────────────────────────────────────────
create table if not exists public.financial_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  name text not null,
  -- `text` + CHECK e não enum: enum é difícil de estender, e a lista de tipos de
  -- conta cresce com o negócio (carteira digital, aplicação, adquirente).
  kind text not null default 'cash' check (kind in ('cash', 'bank', 'other')),

  opening_balance_cents bigint not null default 0,
  currency text not null default 'BRL' check (char_length(currency) = 3),

  -- Inativa-se, não se apaga: conta com lançamento é história, e apagá-la
  -- deixaria o lançamento órfão ou o levaria junto.
  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists financial_accounts_org_nome_key
  on public.financial_accounts (organization_id, lower(name))
  where is_active;
create index if not exists financial_accounts_org_idx
  on public.financial_accounts (organization_id, is_active);

-- ─── como o cliente paga ─────────────────────────────────────────────────────
create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  name text not null,

  -- ⚠️ `on delete restrict`, e é a decisão desta migration: a forma de pagamento
  -- é quem diz em que conta o dinheiro cai. Apagar a conta em cascata deixaria
  -- formas apontando para o nada e lançamentos futuros sem destino — em
  -- silêncio. `restrict` obriga a inativar a conta, que é o caminho certo.
  account_id uuid references public.financial_accounts(id) on delete restrict,

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists payment_methods_org_nome_key
  on public.payment_methods (organization_id, lower(name))
  where is_active;
create index if not exists payment_methods_org_idx
  on public.payment_methods (organization_id, is_active);

-- ─── a classificação do lançamento ───────────────────────────────────────────
create table if not exists public.account_plans (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  name text not null,
  -- Entrada ou saída. O sistema de origem tinha TODAS as 17 linhas como
  -- 'debito', inclusive "Serviços" e "Comissão", que são coisas opostas — um
  -- campo que existe e não distingue nada. Aqui ele distingue, e o CHECK
  -- garante que continue distinguindo.
  direction text not null check (direction in ('in', 'out')),

  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists account_plans_org_nome_key
  on public.account_plans (organization_id, lower(name))
  where is_active;
create index if not exists account_plans_org_idx
  on public.account_plans (organization_id, is_active, direction);

-- ─── RLS: as três são tenant-aware e seguem o helper da casa ─────────────────
--
-- Leitura para quem é da organização; escrita para manager+. Dinheiro não é
-- coisa que `agent` configure — quem atende não define plano de contas.
do $$
declare t text;
begin
  foreach t in array array['financial_accounts', 'payment_methods', 'account_plans'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists tenant_isolation_%I_all on public.%I', t, t);
    execute format($f$
      create policy tenant_isolation_%I_all on public.%I
        for all
        using (organization_id in (select public.fn_user_org_ids()) or public.fn_is_platform_admin())
        with check (
          public.fn_is_platform_admin()
          or (organization_id in (select public.fn_user_org_ids())
              and public.fn_role_at_least(organization_id, 'manager'))
        )
    $f$, t, t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- `updated_at` pelo mesmo trigger que o resto da base usa, se ele existir nesta
-- instalação. `if exists` porque o baseline de um clone antigo pode não tê-lo, e
-- uma migration que falha por causa de carimbo de data é migration que trava
-- atualização por nada.
do $$
declare t text;
begin
  if exists (select 1 from pg_proc where proname = 'fn_touch_updated_at') then
    foreach t in array array['financial_accounts', 'payment_methods', 'account_plans'] loop
      execute format('drop trigger if exists trg_%I_touch on public.%I', t, t);
      execute format(
        'create trigger trg_%I_touch before update on public.%I for each row execute function public.fn_touch_updated_at()',
        t, t);
    end loop;
  end if;
end $$;

comment on table public.financial_accounts is
  'Onde o dinheiro fica. `opening_balance_cents` é o saldo INICIAL declarado; o saldo corrente é sempre derivado por soma dos lançamentos, nunca gravado.';
comment on table public.payment_methods is
  'Como o cliente paga. `account_id` decide em qual conta a entrada cai quando a comanda é finalizada.';
comment on table public.account_plans is
  'Classificação do lançamento, com direção (in/out) que o sistema de origem tinha e não usava.';


-- ---- comanda, financeiro, comissão e fidelidade (migration 0351) ----
-- A COMANDA E O QUE ELA MOVE — segunda e última camada do módulo financeiro.
--
-- Cinco tabelas e uma função. A função é o ponto: finalizar uma comanda faz
-- SEIS coisas numa única transação — marca a venda, gera comissão por item,
-- lança a entrada na conta que a forma de pagamento determina, dá o ponto de
-- fidelidade e conclui o agendamento. Não são módulos vizinhos; é o corpo da
-- mesma transação, e é por isso que nascem juntos.
--
-- ═══ OS INVARIANTES, E POR QUE CADA UM ═══
--
-- 1. NADA É APAGADO. Comanda cancela, conta inativa, item sai por cancelamento
--    da comanda. `delete` em linha de dinheiro é reescrever o passado.
-- 2. SALDO É SEMPRE DERIVADO. Não existe coluna de saldo em lugar nenhum —
--    nem na conta, nem no cliente. Saldo gravado e lançamentos divergem no
--    primeiro estorno, e a divergência não dá sinal.
-- 3. ESTORNO É CONTRA-LANÇAMENTO, nunca exclusão. Duas linhas que se somam a
--    zero contam a história; uma linha apagada não conta nada.
-- 4. A COMISSÃO É RESOLVIDA NA INCLUSÃO DO ITEM e gravada na linha. A
--    finalização NÃO recalcula: mudar a regra de comissão amanhã não pode
--    mexer no que já foi combinado ontem.
-- 5. A NUMERAÇÃO NÃO REINICIA. Sequência por organização, monotônica.
-- 6. LANÇAMENTO PAGO É IMUTÁVEL. Trigger recusa UPDATE que mexa em valor,
--    conta ou data depois de `paid_at`.

-- ─── a comanda ───────────────────────────────────────────────────────────────
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  -- Número visível, por organização. `bigint` e não `serial`: a sequência é
  -- própria de cada tenant (ver `fn_proximo_numero_de_comanda`), e um serial
  -- global vazaria o volume de um cliente para outro.
  number bigint not null,

  contact_id uuid references public.contacts(id) on delete set null,
  -- Quem atendeu. `set null` porque a pessoa pode sair da equipe e a venda
  -- continua tendo acontecido.
  attendant_user_id uuid references auth.users(id) on delete set null,
  appointment_id uuid references public.calendar_appointments(id) on delete set null,

  status text not null default 'open'
    check (status in ('open', 'finalized', 'cancelled')),

  -- Desconto da COMANDA, separado do desconto de item. Fidelidade e comissão
  -- incidem sobre o item, nunca sobre este — senão um desconto de caixa
  -- reduziria o prêmio de quem atendeu.
  discount_cents bigint not null default 0 check (discount_cents >= 0),
  total_cents bigint not null default 0,
  currency text not null default 'BRL' check (char_length(currency) = 3),

  payment_method_id uuid references public.payment_methods(id) on delete restrict,

  notes text,
  finalized_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  -- Estornada: a comanda continua finalizada e ganha o contra-lançamento.
  reversed_at timestamptz,
  reverse_reason text,

  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Finalizar exige forma de pagamento: é ela que diz em que conta o dinheiro
  -- cai. Sem isso, a entrada não teria destino — e o CHECK diz isso no schema,
  -- não numa validação que alguém pode esquecer de chamar.
  constraint sales_finalizada_tem_forma
    check (status <> 'finalized' or payment_method_id is not null)
);

create unique index if not exists sales_org_numero_key on public.sales (organization_id, number);
create index if not exists sales_org_status_idx on public.sales (organization_id, status, created_at desc);
create index if not exists sales_org_contato_idx on public.sales (organization_id, contact_id);
create index if not exists sales_appointment_idx on public.sales (appointment_id)
  where appointment_id is not null;

-- ─── o item ──────────────────────────────────────────────────────────────────
create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  -- `cascade` aqui e só aqui: item não existe fora da comanda, e comanda não é
  -- apagada (cancela). O cascade só dispara se a ORGANIZAÇÃO inteira sair.
  sale_id uuid not null references public.sales(id) on delete cascade,

  -- O que foi feito. `event_type_id` porque, neste produto, o catálogo de
  -- serviços JÁ é `calendar_event_types` — criar uma tabela de serviços ao lado
  -- seria a segunda fonte da mesma verdade.
  event_type_id uuid references public.calendar_event_types(id) on delete restrict,
  -- Congelado na inclusão: o nome muda, a linha da venda não.
  description text not null,

  attendant_user_id uuid references auth.users(id) on delete set null,

  quantity integer not null default 1 check (quantity > 0),
  unit_price_cents bigint not null check (unit_price_cents >= 0),
  discount_cents bigint not null default 0 check (discount_cents >= 0),
  total_cents bigint not null,

  -- ⚠️ RESOLVIDA NA INCLUSÃO e gravada aqui. A finalização não recalcula:
  -- mudar a regra amanhã não mexe no que já foi combinado ontem.
  commission_percent numeric(5, 2) not null default 0
    check (commission_percent >= 0 and commission_percent <= 100),

  created_at timestamptz not null default now()
);

create index if not exists sale_items_sale_idx on public.sale_items (sale_id);
create index if not exists sale_items_org_idx on public.sale_items (organization_id, created_at desc);

-- ─── a regra de comissão ─────────────────────────────────────────────────────
--
-- Precedência: (pessoa + serviço) → (pessoa) → (serviço). A mais específica
-- vence, e é por isso que as três colunas são nullable com um índice único por
-- combinação — não há linha "curinga" mágica, há ausência.
create table if not exists public.commission_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  attendant_user_id uuid references auth.users(id) on delete cascade,
  event_type_id uuid references public.calendar_event_types(id) on delete cascade,

  percent numeric(5, 2) not null check (percent >= 0 and percent <= 100),

  created_at timestamptz not null default now(),

  -- Pelo menos um dos dois: uma regra sem pessoa E sem serviço seria a regra
  -- "de tudo", que é o default da organização e mora em outro lugar.
  constraint commission_rules_tem_alvo
    check (attendant_user_id is not null or event_type_id is not null)
);

-- `coalesce` no índice: NULL não colide com NULL numa UNIQUE, e sem isto duas
-- regras "só para a Ana" passariam as duas, em silêncio.
create unique index if not exists commission_rules_alvo_key on public.commission_rules (
  organization_id,
  coalesce(attendant_user_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(event_type_id, '00000000-0000-0000-0000-000000000000'::uuid)
);

-- ─── a comissão gerada ───────────────────────────────────────────────────────
create table if not exists public.commissions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sale_item_id uuid not null references public.sale_items(id) on delete cascade,
  attendant_user_id uuid not null references auth.users(id) on delete restrict,

  percent numeric(5, 2) not null,
  amount_cents bigint not null,

  status text not null default 'pending' check (status in ('pending', 'paid', 'reversed')),
  paid_at timestamptz,
  reversed_at timestamptz,

  created_at timestamptz not null default now()
);

create unique index if not exists commissions_item_key on public.commissions (sale_item_id);
create index if not exists commissions_org_pessoa_idx
  on public.commissions (organization_id, attendant_user_id, status);

-- ─── o lançamento financeiro ─────────────────────────────────────────────────
create table if not exists public.financial_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  account_id uuid not null references public.financial_accounts(id) on delete restrict,
  account_plan_id uuid references public.account_plans(id) on delete restrict,
  sale_id uuid references public.sales(id) on delete set null,

  direction text not null check (direction in ('in', 'out')),
  -- SEMPRE positivo; quem dá o sinal é `direction`. Valor negativo com direção
  -- é duas formas de dizer a mesma coisa, e elas divergem.
  amount_cents bigint not null check (amount_cents > 0),
  currency text not null default 'BRL' check (char_length(currency) = 3),

  description text,
  entry_date date not null default current_date,

  status text not null default 'pending' check (status in ('pending', 'paid')),
  paid_at timestamptz,

  -- O contra-lançamento aponta para o que ele estorna. Duas linhas que se somam
  -- a zero, e a ligação entre elas explícita.
  reverses_entry_id uuid references public.financial_entries(id) on delete restrict,

  origin text not null default 'manual'
    check (origin in ('manual', 'sale', 'reversal', 'recurring')),

  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists financial_entries_org_data_idx
  on public.financial_entries (organization_id, entry_date desc);
create index if not exists financial_entries_conta_idx
  on public.financial_entries (organization_id, account_id, status);
create index if not exists financial_entries_sale_idx
  on public.financial_entries (sale_id) where sale_id is not null;

-- ─── o livro-razão da fidelidade ─────────────────────────────────────────────
--
-- LEDGER, não saldo. O saldo do cliente é `sum(points)` e nunca uma coluna:
-- guardar o saldo faria o primeiro estorno divergir em silêncio.
create table if not exists public.loyalty_ledger (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,

  -- Assinado: ganhar é positivo, resgatar é negativo. Uma coluna de "tipo" ao
  -- lado seria a segunda forma de dizer o mesmo sinal.
  points integer not null,
  reason text not null,

  sale_id uuid references public.sales(id) on delete set null,
  sale_item_id uuid references public.sale_items(id) on delete set null,

  -- Idempotência do ganho: finalizar a mesma comanda duas vezes não dá ponto
  -- em dobro. A UNIQUE parcial é a garantia, não a boa intenção de quem chama.
  idempotency_key text,

  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists loyalty_ledger_idem_key
  on public.loyalty_ledger (organization_id, idempotency_key)
  where idempotency_key is not null;
create index if not exists loyalty_ledger_contato_idx
  on public.loyalty_ledger (organization_id, contact_id, created_at desc);

-- ─── lançamento pago é imutável ──────────────────────────────────────────────
create or replace function public.fn_lancamento_pago_e_imutavel()
returns trigger language plpgsql as $$
begin
  if old.paid_at is not null and (
       new.amount_cents is distinct from old.amount_cents
    or new.account_id   is distinct from old.account_id
    or new.direction    is distinct from old.direction
    or new.entry_date   is distinct from old.entry_date
  ) then
    -- Não é capricho: um lançamento pago já foi conciliado com extrato. Mudá-lo
    -- faz o relatório de ontem contar outra história hoje, sem deixar rastro.
    -- O caminho certo é o contra-lançamento.
    raise exception 'lancamento_pago_imutavel'
      using errcode = '42501',
            hint = 'Um lançamento já pago não muda de valor, conta, direção ou data. Estorne com um contra-lançamento.';
  end if;
  return new;
end $$;

drop trigger if exists trg_financial_entries_imutavel on public.financial_entries;
create trigger trg_financial_entries_imutavel
  before update on public.financial_entries
  for each row execute function public.fn_lancamento_pago_e_imutavel();

-- ─── a numeração que não reinicia ────────────────────────────────────────────
-- ⚠️ `security invoker` (o default), e NÃO definer, de propósito. Ela só LÊ
-- `public.sales`, e a RLS daquela tabela já é a cerca: com a sessão de quem
-- chama, o `max(number)` só enxerga a própria organização. Definer aqui
-- responderia a qualquer usuário logado qual é o número da próxima comanda de
-- QUALQUER organização — que é exatamente o volume de vendas do vizinho, o
-- vazamento que o comentário abaixo diz querer evitar. A varredura
-- `tests/invariants/definer-membership-varredura.test.ts` mede isso.
create or replace function public.fn_proximo_numero_de_comanda(p_org uuid)
returns bigint language sql stable set search_path = public as $$
  -- `coalesce(max)+1` sob o lock da transação de quem chama. Uma sequence do
  -- Postgres seria global e vazaria volume entre tenants; e o buraco de uma
  -- sequence (números pulados no rollback) faria a numeração de uma comanda
  -- parecer que houve venda cancelada onde não houve.
  select coalesce(max(number), 0) + 1 from public.sales where organization_id = p_org;
$$;
revoke execute on function public.fn_proximo_numero_de_comanda(uuid) from public, anon;
grant execute on function public.fn_proximo_numero_de_comanda(uuid) to authenticated, service_role;

-- ─── A FINALIZAÇÃO: as seis coisas numa transação ────────────────────────────
create or replace function public.fn_finalizar_comanda(
  p_org uuid,
  p_sale uuid,
  p_payment_method uuid,
  p_loyalty_points integer default 0
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sale       public.sales%rowtype;
  v_conta      uuid;
  v_plano      uuid;
  v_total      bigint;
  v_item       record;
  v_entry      uuid;
begin
  if auth.uid() is null or not public.fn_role_at_least(p_org, 'agent') then
    raise exception 'comanda_forbidden' using errcode = '42501';
  end if;

  -- FOR UPDATE: duas finalizações simultâneas da mesma comanda geravam
  -- lançamento em dobro. O lock é o que torna esta função idempotente de fato,
  -- e não só na intenção.
  select * into v_sale from public.sales
   where id = p_sale and organization_id = p_org
   for update;

  if not found then
    raise exception 'comanda_nao_encontrada' using errcode = 'P0002';
  end if;
  if v_sale.status = 'finalized' then
    -- Não é erro: quem chamou duas vezes recebe o mesmo desfecho.
    return jsonb_build_object('sale_id', v_sale.id, 'ja_finalizada', true);
  end if;
  if v_sale.status = 'cancelled' then
    raise exception 'comanda_cancelada' using errcode = '22023';
  end if;

  select account_id into v_conta from public.payment_methods
   where id = p_payment_method and organization_id = p_org and is_active;
  if not found then
    raise exception 'forma_de_pagamento_invalida' using errcode = '22023';
  end if;
  if v_conta is null then
    -- A forma existe e não diz para onde o dinheiro vai. Recusar aqui é melhor
    -- que escolher uma conta por conta própria.
    raise exception 'forma_sem_conta'
      using errcode = '22023',
            hint = 'Esta forma de pagamento ainda não tem conta de destino. Defina em Configurações → Financeiro.';
  end if;

  select coalesce(sum(total_cents), 0) into v_total
    from public.sale_items where sale_id = p_sale;
  v_total := greatest(v_total - coalesce(v_sale.discount_cents, 0), 0);

  -- (1) a venda
  update public.sales
     set status = 'finalized',
         finalized_at = now(),
         payment_method_id = p_payment_method,
         total_cents = v_total
   where id = p_sale;

  -- (2) a comissão por item, com o percentual CONGELADO na inclusão
  for v_item in
    select * from public.sale_items where sale_id = p_sale and attendant_user_id is not null
  loop
    insert into public.commissions
      (organization_id, sale_item_id, attendant_user_id, percent, amount_cents)
    values (
      p_org, v_item.id, v_item.attendant_user_id, v_item.commission_percent,
      -- Sobre o item, NUNCA sobre o desconto da comanda: um desconto de caixa
      -- não pode reduzir o que quem atendeu combinou.
      floor(v_item.total_cents * v_item.commission_percent / 100.0)
    )
    on conflict (sale_item_id) do nothing;
  end loop;

  -- (3) a entrada na conta que a FORMA DE PAGAMENTO determina
  select id into v_plano from public.account_plans
   where organization_id = p_org and direction = 'in' and is_active
   order by created_at limit 1;

  insert into public.financial_entries
    (organization_id, account_id, account_plan_id, sale_id, direction, amount_cents,
     currency, description, status, paid_at, origin, created_by_user_id)
  values (
    p_org, v_conta, v_plano, p_sale, 'in', greatest(v_total, 1),
    v_sale.currency, format('Comanda #%s', v_sale.number), 'paid', now(), 'sale', auth.uid()
  )
  returning id into v_entry;

  -- (4) o ponto de fidelidade, idempotente pela chave da comanda
  if p_loyalty_points > 0 and v_sale.contact_id is not null then
    insert into public.loyalty_ledger
      (organization_id, contact_id, points, reason, sale_id, idempotency_key, created_by_user_id)
    values (
      p_org, v_sale.contact_id, p_loyalty_points, 'Comanda finalizada', p_sale,
      format('sale:%s', p_sale), auth.uid()
    )
    on conflict do nothing;
  end if;

  -- (5) o agendamento conclui — e SÓ se ainda estiver de pé.
  if v_sale.appointment_id is not null then
    update public.calendar_appointments
       set status = 'completed', outcome_recorded_at = now()
     where id = v_sale.appointment_id
       and organization_id = p_org
       -- A guarda que o sistema de origem não tinha em todos os caminhos:
       -- cancelado e faltou são desfechos DECIDIDOS, e faturar não os desfaz.
       and status not in ('cancelled', 'no_show');
  end if;

  return jsonb_build_object(
    'sale_id', v_sale.id,
    'number', v_sale.number,
    'total_cents', v_total,
    'entry_id', v_entry
  );
end $$;

revoke execute on function public.fn_finalizar_comanda(uuid, uuid, uuid, integer) from public, anon;
grant execute on function public.fn_finalizar_comanda(uuid, uuid, uuid, integer) to authenticated;

-- ─── O ESTORNO: contra-lançamento, nunca exclusão ────────────────────────────
create or replace function public.fn_estornar_comanda(p_org uuid, p_sale uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_sale   public.sales%rowtype;
  v_orig   public.financial_entries%rowtype;
  v_novo   uuid;
begin
  if auth.uid() is null or not public.fn_role_at_least(p_org, 'manager') then
    raise exception 'estorno_forbidden' using errcode = '42501';
  end if;

  select * into v_sale from public.sales
   where id = p_sale and organization_id = p_org for update;
  if not found then raise exception 'comanda_nao_encontrada' using errcode = 'P0002'; end if;
  if v_sale.status <> 'finalized' then
    raise exception 'comanda_nao_finalizada' using errcode = '22023';
  end if;
  if v_sale.reversed_at is not null then
    return jsonb_build_object('sale_id', v_sale.id, 'ja_estornada', true);
  end if;

  update public.sales set reversed_at = now(), reverse_reason = p_motivo where id = p_sale;

  -- O contra-lançamento de cada entrada da comanda. A original NÃO é tocada:
  -- ela está paga e é imutável (o trigger acima recusaria).
  for v_orig in
    select * from public.financial_entries
     where sale_id = p_sale and organization_id = p_org and origin = 'sale'
  loop
    insert into public.financial_entries
      (organization_id, account_id, account_plan_id, sale_id, direction, amount_cents,
       currency, description, status, paid_at, origin, reverses_entry_id, created_by_user_id)
    values (
      p_org, v_orig.account_id, v_orig.account_plan_id, p_sale,
      case when v_orig.direction = 'in' then 'out' else 'in' end,
      v_orig.amount_cents, v_orig.currency,
      format('Estorno da comanda #%s', v_sale.number), 'paid', now(), 'reversal',
      v_orig.id, auth.uid()
    )
    returning id into v_novo;
  end loop;

  -- A comissão vira 'reversed' — não some, porque ela existiu e alguém pode já
  -- ter sido pago por ela.
  update public.commissions c
     set status = 'reversed', reversed_at = now()
    from public.sale_items i
   where c.sale_item_id = i.id and i.sale_id = p_sale and c.status <> 'reversed';

  -- E o ponto de fidelidade volta como movimento NEGATIVO, nunca apagando o
  -- ganho: o livro-razão conta as duas coisas.
  insert into public.loyalty_ledger
    (organization_id, contact_id, points, reason, sale_id, idempotency_key, created_by_user_id)
  select p_org, v_sale.contact_id, -l.points, 'Estorno da comanda', p_sale,
         format('reversal:%s', p_sale), auth.uid()
    from public.loyalty_ledger l
   where l.sale_id = p_sale and l.organization_id = p_org and l.points > 0
     and v_sale.contact_id is not null
  on conflict do nothing;

  return jsonb_build_object('sale_id', v_sale.id, 'estornada', true);
end $$;

revoke execute on function public.fn_estornar_comanda(uuid, uuid, text) from public, anon;
grant execute on function public.fn_estornar_comanda(uuid, uuid, text) to authenticated;

-- ─── RLS nas cinco ───────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['sales', 'sale_items', 'commission_rules', 'commissions',
                           'financial_entries', 'loyalty_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists tenant_isolation_%I_all on public.%I', t, t);
    execute format($f$
      create policy tenant_isolation_%I_all on public.%I
        for all
        using (organization_id in (select public.fn_user_org_ids()) or public.fn_is_platform_admin())
        with check (
          public.fn_is_platform_admin()
          or (organization_id in (select public.fn_user_org_ids())
              and public.fn_role_at_least(organization_id, 'agent'))
        )
    $f$, t, t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

comment on table public.sales is
  'A comanda. Cancela, nunca apaga. `number` é sequencial por organização e não reinicia.';
comment on table public.loyalty_ledger is
  'Livro-razão de fidelidade. O saldo do cliente é sum(points) — NUNCA uma coluna.';
comment on function public.fn_finalizar_comanda(uuid, uuid, uuid, integer) is
  'As seis coisas numa transação: venda, comissão por item, entrada na conta da forma de pagamento, ponto de fidelidade e conclusão do agendamento. Idempotente sob FOR UPDATE.';


-- ---- uma comanda por agendamento (migration 0352) ----
-- A rota consulta antes de abrir, e isso resolve o toque repetido, não a
-- corrida: duas requisições simultâneas passam pelas duas consultas antes de
-- qualquer insert. Duas comandas abertas para o mesmo atendimento não dão erro
-- nenhum — são faturadas separadamente, e o cliente paga duas vezes.
--
-- Parcial nas duas pontas: comanda avulsa é a maioria e não se exclui entre si;
-- comanda cancelada deixa de valer, senão cancelar por engano trancaria o
-- agendamento para sempre.
update public.sales s
   set appointment_id = null
 where s.appointment_id is not null
   and s.status <> 'cancelled'
   and exists (
     select 1 from public.sales anterior
      where anterior.appointment_id = s.appointment_id
        and anterior.organization_id = s.organization_id
        and anterior.status <> 'cancelled'
        and (anterior.created_at, anterior.id) < (s.created_at, s.id)
   );

create unique index if not exists sales_agendamento_unico_idx
  on public.sales (organization_id, appointment_id)
  where appointment_id is not null and status <> 'cancelled';

-- ---- relatório financeiro (migrations 0353 + 0356) ----
-- Agrega NO BANCO: o PostgREST corta em 1000 linhas sem avisar, e somar na
-- aplicação devolve um número menor com cara de certo (medido nesta base:
-- R$ 141.436,00 em vez de R$ 641.103,60). Invoker, para a RLS de cada tabela
-- continuar valendo.
--
-- O corpo abaixo é o da 0247, que ACRESCENTOU `por_servico` e `por_cliente`
-- sem mudar a assinatura. O apêndice guarda o estado final, nunca as duas
-- versões empilhadas — senão quem lê o baseline vê a definição antiga
-- primeiro e conclui que ela é a que vale.
create or replace function public.fn_relatorio_financeiro(
  p_org uuid,
  p_de date,
  p_ate date
)
returns jsonb
language sql
stable
set search_path = public
as $$
  with lancamentos as (
    select direction, amount_cents
      from public.financial_entries
     where organization_id = p_org
       and status = 'paid'
       and entry_date between p_de and p_ate
  ),
  comandas as (
    select id, status, total_cents, reversed_at, payment_method_id, contact_id
      from public.sales
     where organization_id = p_org
       and finalized_at is not null
       and finalized_at::date between p_de and p_ate
  ),
  por_forma as (
    select coalesce(pm.name, 'Sem forma') as nome,
           count(*)                       as quantidade,
           sum(c.total_cents)             as total_cents
      from comandas c
      left join public.payment_methods pm
        on pm.id = c.payment_method_id and pm.organization_id = p_org
     group by 1
  ),
  por_profissional as (
    select co.attendant_user_id,
           count(*)              as itens,
           sum(co.amount_cents)  as comissao_cents
      from public.commissions co
      join public.sale_items si
        on si.id = co.sale_item_id and si.organization_id = p_org
      join comandas s on s.id = si.sale_id
     where co.organization_id = p_org
       and co.status <> 'reversed'
     group by 1
  ),
  por_servico as (
    -- Agrupa pela DESCRIÇÃO congelada no item, e não pelo nome atual do tipo de
    -- evento. É o que o cliente comprou, com o nome que tinha na hora — e é o
    -- único agrupamento que continua verdadeiro depois de alguém renomear um
    -- serviço. O item avulso (sem `event_type_id`) entra por aqui também, em vez
    -- de sumir do relatório.
    select si.description       as nome,
           sum(si.quantity)     as quantidade,
           sum(si.total_cents)  as total_cents
      from public.sale_items si
      join comandas s on s.id = si.sale_id
     where si.organization_id = p_org
     group by 1
  ),
  por_cliente as (
    select c.contact_id,
           count(*)             as comandas,
           sum(c.total_cents)   as total_cents
      from comandas c
     where c.contact_id is not null
     group by 1
  )
  select jsonb_build_object(
    'de', p_de,
    'ate', p_ate,
    'entradas_cents', coalesce((select sum(amount_cents) from lancamentos where direction = 'in'), 0),
    'saidas_cents',   coalesce((select sum(amount_cents) from lancamentos where direction = 'out'), 0),
    'saldo_cents',    coalesce((select sum(case when direction = 'in' then amount_cents else -amount_cents end) from lancamentos), 0),
    'comandas_finalizadas', (select count(*) from comandas),
    'comandas_estornadas',  (select count(*) from comandas where reversed_at is not null),
    'faturado_cents',       coalesce((select sum(total_cents) from comandas), 0),
    'ticket_medio_cents',   coalesce((select sum(total_cents) / nullif(count(*), 0) from comandas), 0),
    'por_forma', coalesce((
      select jsonb_agg(jsonb_build_object('nome', nome, 'quantidade', quantidade, 'total_cents', total_cents)
             order by total_cents desc)
        from por_forma
    ), '[]'::jsonb),
    'por_profissional', coalesce((
      select jsonb_agg(jsonb_build_object('attendant_user_id', attendant_user_id, 'itens', itens, 'comissao_cents', comissao_cents)
             order by comissao_cents desc)
        from por_profissional
    ), '[]'::jsonb),
    'por_servico', coalesce((
      select jsonb_agg(jsonb_build_object('nome', nome, 'quantidade', quantidade, 'total_cents', total_cents)
             order by total_cents desc)
        from (select * from por_servico order by total_cents desc limit 10) t
    ), '[]'::jsonb),
    'por_cliente', coalesce((
      select jsonb_agg(jsonb_build_object('contact_id', contact_id, 'comandas', comandas, 'total_cents', total_cents)
             order by total_cents desc)
        from (select * from por_cliente order by total_cents desc limit 10) t
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.fn_relatorio_financeiro(uuid, date, date) from public, anon;
grant  execute on function public.fn_relatorio_financeiro(uuid, date, date) to authenticated, service_role;

-- ---- regra de comissao inativa (migration 0354) ----
-- A regra entra no catálogo financeiro genérico, que espera `is_active`.
-- Antes disto não havia porta nenhuma para cadastrar uma regra, e toda
-- comissão nascia 0% em toda instalação. Inativar e não apagar preserva a
-- resposta a "por que aquela comanda saiu com este percentual".
-- `name` é o rótulo que a pessoa lê na lista ("Ana em manicure"). Ele é
-- redundante com os dois alvos, e a redundância é deliberada: o catálogo
-- genérico exige um nome em toda entidade, e derivá-lo no servidor produziria um
-- texto que ninguém pode corrigir quando ficar ambíguo.
alter table public.commission_rules
  add column if not exists name text not null default 'Regra de comissão';

alter table public.commission_rules
  add column if not exists is_active boolean not null default true;

create index if not exists commission_rules_org_ativas_idx
  on public.commission_rules (organization_id, event_type_id, attendant_user_id)
  where is_active;

comment on column public.commission_rules.is_active is
  'Regra em vigor. Inativa em vez de apagar: o percentual já aplicado está congelado no item, e o que se perderia é a resposta a "por que aquela comanda saiu com este percentual".';

-- ---- saldo de fidelidade (migration 0355) ----
-- O saldo é sum(points) do livro-razão, somado NO BANCO: o PostgREST corta em
-- 1000 linhas sem avisar, e saldo truncado vira prêmio negado a quem tinha
-- direito. Por CLIENTE, nunca agregado — o total geral esconde erros que se
-- compensam.
create or replace function public.fn_saldo_de_fidelidade(p_org uuid, p_contact uuid)
returns integer
language sql
stable
set search_path = public
as $$
  select coalesce(sum(points), 0)::integer
    from public.loyalty_ledger
   where organization_id = p_org
     and contact_id = p_contact;
$$;

revoke execute on function public.fn_saldo_de_fidelidade(uuid, uuid) from public, anon;
grant  execute on function public.fn_saldo_de_fidelidade(uuid, uuid) to authenticated, service_role;

comment on function public.fn_saldo_de_fidelidade(uuid, uuid) is
  'Saldo de pontos de um contato: sum(points) do livro-razão. Soma no banco porque o PostgREST corta em 1000 linhas sem avisar, e saldo truncado vira prêmio negado a quem tinha direito.';

-- ---- lancamento recorrente (migration 0357) ----
-- O molde de um lançamento que se repete todo mês. Não movimenta dinheiro:
-- quem nasce é uma linha PENDENTE em `financial_entries`. Nasce pendente e
-- nunca paga — o sistema sabe que a conta vence, não sabe se alguém pagou.
--
-- A idempotência é do BANCO (índice único por molde e competência), e não de
-- uma flag de "último gerado": esta resolveria o caso comum e falharia
-- exatamente no que importa, duas execuções simultâneas.
create table if not exists public.recurring_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,

  name text not null,
  account_id uuid not null references public.financial_accounts(id) on delete restrict,
  account_plan_id uuid references public.account_plans(id) on delete restrict,

  direction text not null check (direction in ('in', 'out')),
  amount_cents bigint not null check (amount_cents > 0),
  currency text not null default 'BRL' check (char_length(currency) = 3),

  -- 1 a 31. O que não existe no mês cai no último dia dele.
  day_of_month integer not null check (day_of_month between 1 and 31),

  -- Inativa-se, não se apaga: o molde explica os lançamentos que ele gerou.
  is_active boolean not null default true,

  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists recurring_entries_org_ativas_idx
  on public.recurring_entries (organization_id)
  where is_active;

alter table public.financial_entries
  add column if not exists recurring_entry_id uuid
  references public.recurring_entries(id) on delete set null;

-- A GARANTIA de que a mesma competência não nasce duas vezes. Parcial porque a
-- imensa maioria dos lançamentos não vem de molde nenhum.
create unique index if not exists financial_entries_recorrencia_competencia_idx
  on public.financial_entries (recurring_entry_id, entry_date)
  where recurring_entry_id is not null;

alter table public.recurring_entries enable row level security;
drop policy if exists tenant_isolation_recurring_entries_all on public.recurring_entries;
create policy tenant_isolation_recurring_entries_all on public.recurring_entries
  for all
  using (organization_id in (select public.fn_user_org_ids()) or public.fn_is_platform_admin())
  with check (
    public.fn_is_platform_admin()
    or (organization_id in (select public.fn_user_org_ids())
        and public.fn_role_at_least(organization_id, 'manager'))
  );
revoke all on public.recurring_entries from anon;

comment on table public.recurring_entries is
  'O molde de um lançamento que se repete todo mês. Não movimenta dinheiro: quem nasce é uma linha pendente em financial_entries. Mudar o molde não reescreve o que já foi gerado.';
comment on column public.recurring_entries.day_of_month is
  'Dia do mês, 1 a 31. O que não existe no mês cai no último dia dele — pular deixaria de cobrar o aluguel em fevereiro.';

-- ---- preco do tipo de evento (migration 0358) ----
-- O catálogo de serviços JÁ é o de tipos de agendamento (decisão da 0240), e
-- faltava o preço. Sem ele o balcão digita valor a cada item e o faturamento
-- em lote é impossível. NULLABLE: nem todo negócio tem preço fixo, e vazio
-- significa "digite na hora", que é o comportamento de antes desta migration.
-- É SEMENTE, nunca preço final — o item congela o seu próprio valor.
alter table public.calendar_event_types
  add column if not exists default_price_cents bigint
  check (default_price_cents is null or default_price_cents >= 0);

comment on column public.calendar_event_types.default_price_cents is
  'Preço padrão do serviço, em centavos. Vazio = digite na hora. É SEMENTE do item da comanda, nunca o preço dele: o item guarda o seu próprio unit_price_cents, congelado na inclusão.';

-- ---- a cascata de anonimizacao alcanca a comanda (migration 0359) ----
-- A CASCATA DE ANONIMIZAÇÃO ALCANÇA A COMANDA (forward-fix da 0351).
--
-- As migrations 0350-0357 trouxeram o módulo financeiro, e `sales` guarda
-- `notes`, `cancel_reason` e `reverse_reason` — texto livre que um atendente
-- escreve SOBRE a pessoa — com FK para `contacts`. Fora da cascata, anonimizar
-- devolvia SUCESSO e o texto continuava legível: a falha é muda, e o SLA de
-- D+15 é marcado como cumprido sobre um dado que não saiu.
--
-- Forward-fix e não edição da 0351 porque a cascata é uma função do NÚCLEO,
-- anterior a este módulo — o passo pertence a ela, não à migration que criou a
-- tabela. `create or replace` da função inteira: ela percorre uma lista escrita
-- à mão, e não há como acrescentar um passo sem reemiti-la.
--
-- Vigiado por `tests/invariants/lgpd-cascata-alcanca-quem-guarda-pessoa.test.ts`,
-- que deriva o escopo do CATÁLOGO (FK para contacts + coluna de PII) e lê o
-- corpo REAL da função instalada — não uma lista de tabelas escrita ao lado.

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
  perform public.fn_service_lock(p_organization_id,p_contact_id);
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
    -- O motivo CRU da última passagem (migration 0291). É código de
    -- vocabulário, não texto livre — mas ele diz que ESTA pessoa foi escalada
    -- por irritação, por assunto jurídico ou por suspeita de opt-out, e isso é
    -- um fato sobre ela. Entra NESTE update, e não num segundo: mesmo
    -- predicado, mesmas linhas, metade das varreduras.
    --
    -- ⚠️ `last_handoff_reason` é CHAVE DE NEGÓCIO em outro módulo: a ponte de
    -- voz limpa o silêncio filtrando pelo VALOR da coluna
    -- (`lib/wacalls/events-bridge.ts`). Zerá-la num contato anonimizado é
    -- seguro — não há chamada viva de contato anonimizado — e é a razão de
    -- esta entrega NÃO usar essa coluna para texto rico: ela continua
    -- recebendo só o código, e o texto vive em `passagens_de_atendimento`.
    last_handoff_reason = null,
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

  -- 6b. sales — a comanda. PRESERVA valor, status e datas, e NÃO desliga o
  --     contato: a venda é registro financeiro (e fiscal) da organização, e
  --     desligá-la do contato faria o relatório por cliente deixar de fechar
  --     com o faturamento do período — divergência muda, meses depois, num
  --     número que ninguém consegue reconciliar. O contato apontado já é
  --     `Cliente Anonimizado #N`; o que sai daqui é o TEXTO LIVRE, que é onde
  --     a pessoa é nomeada de novo ("cliente da Ana, filha da Dona Maria").
  --     Os itens (`sale_items`) não entram: `description` ali é o nome do
  --     SERVIÇO, congelado na inclusão, e apagá-lo destruiria o relatório por
  --     serviço sem tirar dado de pessoa nenhum.
  update sales set
    notes = null,
    cancel_reason = case when cancel_reason is null then null else '[redigido]' end,
    reverse_reason = case when reverse_reason is null then null else '[redigido]' end,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('sales', v_count);

  -- 7. enqueue media for async deletion (idempotent via unique (bucket, object_path))
  if array_length(v_media_paths, 1) > 0 then
    insert into storage_redaction_queue (organization_id, request_id, bucket, object_path)
    select p_organization_id, p_request_id, 'whatsapp-media', path
      from unnest(v_media_paths) as path
      where path is not null and length(path) > 0
    on conflict (bucket, object_path) do nothing;
  end if;

  -- 7b. voice_calls — o TELEFONE de quem falou ao telefone (migration 0235).
  --
  -- `peer_phone` é `not null` e guarda o número da outra ponta: depois de
  -- anonimizar o contato, ele sobrevivia ligado ao `contact_id` e reidentificava
  -- a pessoa que pediu para ser esquecida. É o mesmo argumento que a foto de
  -- perfil já tinha (ver o bloco do avatar em `lib/lgpd/redact-cascade.ts`):
  -- anonimizar em toda parte menos numa é não ter anonimizado.
  --
  -- O que fica: direção, status, motivo do fim, marcas de tempo e duração. Um
  -- registro de "houve uma chamada de 12 minutos" sem número e sem dono não
  -- identifica ninguém e é o que sustenta a métrica do atendente e a fatura.
  -- `peer_phone` é NOT NULL, então recebe o rótulo, não `null`.
  update voice_calls set
    peer_phone = v_anon_label,
    owner_user_id = null,
    created_by = null,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('voice_calls', v_count);

  -- agent_cases — o que a IA escreveu SOBRE a pessoa quando travou (migration 0280).
  --
  -- O caso é o texto que a equipe lê antes de decidir: `title`, `summary` e
  -- `blocker` saem do modelo a partir da conversa, e `context_snapshot` é o
  -- recorte dessa conversa que o motor mandou para ele. Nada disso é registro de
  -- operação — é o relato do problema de uma pessoa identificável, escrito por
  -- máquina. Sem este passo, anonimizar devolvia SUCESSO com o relato intacto.
  --
  -- As três colunas de texto são `not null`: recebem rótulo e texto fixo, nunca
  -- `null` (a mesma razão de `voice_calls.peer_phone` logo acima).
  --
  -- ⚠️ `updated_at` FICA FORA DO `set`, de propósito. O cobrador de caso parado
  -- (`app/api/v1/cron/case-stale-watcher/route.ts`) lê `updated_at` como "alguém
  -- da equipe encostou neste caso". A cascata não é alguém encostando: escrever
  -- ali faria a anonimização ADIAR a cobrança de um caso que continua parado, e
  -- o efeito só apareceria como um cliente esperando mais tempo.
  --
  -- O vínculo é pela CONVERSA porque `agent_cases` não tem FK para `contacts`.
  update agent_cases set
    title = v_anon_label,
    summary = '[resumo anonimizado]',
    blocker = '[bloqueio anonimizado]',
    context_snapshot = '{}'::jsonb
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_cases', v_count);

  -- agent_case_events — a linha do tempo do caso (migration 0280).
  --
  -- `body` é o que a pessoa da equipe escreveu ao responder o caso e o que o
  -- agente registrou sobre o que o LEAD respondeu; `metadata` carrega o recorte
  -- que o motor anexou. `kind`, `actor_kind`, `human_action` e `created_at`
  -- FICAM: são o registro de que houve um toque humano e quando — operação, não
  -- dado da pessoa, e é deles que sai a métrica de atendimento.
  update agent_case_events set
    body = null,
    metadata = '{}'::jsonb
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_events', v_count);

  -- demandas — o assunto do pedido (migration 0280).
  --
  -- `assunto` é texto livre sobre o que a pessoa pediu. O resto da linha é a
  -- operação da demanda (origem, estado, dono, prazo, desfecho) e fica de pé:
  -- apagar a linha inteira tiraria da organização a resposta a "quantos pedidos
  -- houve em março", que é o mesmo argumento do compromisso da agenda.
  --
  -- FK direta (`demandas.contact_id` é `not null`), então o vínculo é o contato.
  update demandas set
    assunto = null
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('demandas', v_count);

  -- agent_inbox_items — o aviso que leva o texto do caso para a Central (migration 0280).
  --
  -- O `body` do aviso de caso parado EMBUTE o título do caso
  -- (`app/api/v1/cron/case-stale-watcher/route.ts:128`), e o do handoff embute o
  -- motivo da parada (`lib/ai/handoff/orchestrator.ts:335`). Redigir o caso e
  -- deixar o aviso de pé seria anonimizar em toda parte menos numa — que é não
  -- ter anonimizado. O molde (resolver + trocar o corpo + soltar a referência) é
  -- o de `fn_meet_redact_contact`, que já faz isto para o aviso de compromisso.
  --
  -- ⚠️ O VÍNCULO É POLIMÓRFICO E TEM TRÊS BRAÇOS, não dois. Medido nos
  -- produtores, não suposto: `handoff` nasce com `ref_kind='contact'`
  -- (`lib/ai/handoff/orchestrator.ts:339`) E com `ref_kind='conversation'`
  -- (`lib/agent-engine/agent/inbound-turn.ts:4100`); `case_stale` nasce SEMPRE
  -- com `ref_kind='agent_case'` (a rota do cron acima, e a política em
  -- `lib/ai/inbox-destino.ts:38`). Um predicado com só os dois primeiros braços
  -- casa ZERO avisos de caso parado — e casar zero linha não é erro: é sucesso
  -- com o texto intacto.
  --
  -- Os `kind` são os MEDIDOS no CHECK vigente (`supabase/baseline.sql`, bloco
  -- único de `agent_inbox_items_kind_check`). `case_opened` NÃO existe, e kind
  -- inexistente num `in (...)` também casa zero e devolve sucesso. Para
  -- reconferir sem acreditar nesta prosa:
  --   grep -n "agent_inbox_items_kind_check check" -A40 supabase/baseline.sql
  update agent_inbox_items set
    status = 'resolved',
    resolved_at = now(),
    body = 'Contato anonimizado.',
    ref_id = null
  where organization_id = p_organization_id
    -- `aviso_de_caso_nao_entregue` (migration 0292) entra AQUI e não num
    -- passo próprio: é o mesmo predicado polimórfico, e o braço
    -- `ref_kind='agent_case'` já alcança o caso do titular. O corpo do aviso
    -- embute o título do caso, que é texto sobre a pessoa.
    and kind in ('handoff', 'case_stale', 'aviso_de_caso_nao_entregue')
    and (
      (ref_kind = 'contact' and ref_id = p_contact_id)
      or (ref_kind = 'conversation' and ref_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          ))
      or (ref_kind = 'agent_case' and ref_id in (
            select id from agent_cases
              where organization_id = p_organization_id
                and conversation_id in (
                  select id from conversations
                    where contact_id = p_contact_id and organization_id = p_organization_id
                )
          ))
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_inbox_items', v_count);

  -- agent_case_chat_messages — a consulta interna da equipe à IA SOBRE o caso
  -- (migration 0281). FK DIRETA para `contacts`, então o vínculo é o titular e
  -- não precisa passar pela conversa.
  --
  -- `redacted_at is null` no `where` é o que torna o passo IDEMPOTENTE: a
  -- varredura diária de redações incompletas roda a função de novo, e sem essa
  -- condição o carimbo de QUANDO se apagou seria reescrito a cada rodada.
  --
  -- A linha NÃO é apagada, só o texto: quem abrir o caso depois continua vendo
  -- que a equipe perguntou N vezes, quando, e se a IA respondeu. Apagar a linha
  -- inteira ficaria verde num teste de "o texto sumiu" e tiraria da organização
  -- a resposta a "quanto a equipe deliberou sobre este caso".
  update agent_case_chat_messages set
    body = null,
    redacted_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id
    and redacted_at is null;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_chat_messages', v_count);

  -- passagens_de_atendimento — o BRIEFING é sobre a pessoa (migration 0291).
  --
  -- A linha guarda o que a IA concluiu sobre um atendimento de alguém
  -- identificável: o que ela entendeu que a pessoa quer (`title`), a narrativa
  -- que quem assumiu leu (`body`), as PALAVRAS LITERAIS do cliente (`notes`), o
  -- texto livre de quem passou (`content`) e o que a IA já tinha tentado
  -- (`tentativas`). Nada disso é registro de operação — é o relato do problema
  -- de uma pessoa, escrito por máquina, na tela de quem vai responder.
  --
  -- `body` é `not null` e recebe o RÓTULO, não `null` — a mesma razão de
  -- `voice_calls.peer_phone` e de `agent_cases.title` acima: coluna obrigatória
  -- anulada aborta o cascade INTEIRO, e um cascade abortado não anonimiza nada.
  --
  -- O que FICA, de propósito: `motor`, `origem`, `motivo_codigo`,
  -- `cliente_avisado`, `aviso_motivo_codigo`, `criado_em` e o par de
  -- reconhecimento. São operação — quantas passagens houve, por quê, quanto
  -- tempo até alguém assumir. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos atendimentos a IA devolveu em março, e quanto tempo esperaram".
  --
  -- O vínculo é a FK DIRETA `contact_id`: a tabela a carrega exatamente para
  -- este passo não precisar passar pela conversa.
  update passagens_de_atendimento set
    body       = v_anon_label,
    title      = null,
    notes      = null,
    content    = null,
    tentativas = '[]'::jsonb
  where organization_id = p_organization_id and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('passagens_de_atendimento', v_count);

  -- entregas_de_aviso_de_caso — o registro do aviso ao suporte (migration 0292).
  --
  -- A tabela NÃO guarda o texto do aviso (só `corpo_hash`), e a única coluna
  -- capaz de ecoar um dado da pessoa é `erro_detalhe`: ali vai o texto CRU que
  -- o transporte devolveu, truncado, e um provedor que recusa um envio costuma
  -- devolver o destinatário dentro da mensagem de erro.
  --
  -- O que FICA, de propósito: `status`, `erro_codigo`, `tentativas`,
  -- `enviado_em`, `destino`, `corpo_hash`. São operação — quantos avisos saíram,
  -- quantos falharam e por quê. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos avisos não chegaram em março". `destino` é o telefone da EQUIPE,
  -- não do titular: anonimizar um cliente não apaga o número do plantão.
  --
  -- ⚠️ PONTO CEGO DECLARADO: `tests/invariants/lgpd-cascata-alcanca-quem-
  -- guarda-pessoa.test.ts` só cobra tabela com FK para `contacts` E coluna cujo
  -- NOME case o padrão de PII. Esta tabela não satisfaz nenhuma das duas — o
  -- gate ficaria VERDE sem este passo. Ele entra porque é certo, não porque o
  -- gate cobra, e isto está escrito aqui para a próxima sessão não o remover
  -- achando que é ornamento. Quem o vigia é a catraca
  -- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
  --
  -- O vínculo é pela CONVERSA, como o de `agent_cases`: esta tabela aponta para
  -- o caso, e o caso não tem FK para `contacts`.
  update entregas_de_aviso_de_caso set
    erro_detalhe = null
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('entregas_de_aviso_de_caso', v_count);

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

-- ---- a recusa permanente da agenda não pede repetição (migration 0363) ----
-- `PT409` no lugar de `40001` nas três recusas PERMANENTES de `fn_meet_action`.
-- `40001` vira HTTP 500 no PostgREST e o gateway do Supabase reexecuta 5xx sem
-- limite (docs/runbooks/postgrest-replay-do-gateway.md); `PTxxx` chega como o
-- status dos três últimos dígitos, e 4xx não é reexecutado. Corpo idêntico ao
-- da definição acima, com três `errcode` trocados. Idempotente.
-- Recorte do PR #803, de @paulolimajr77.

create or replace function public.fn_meet_action(p_org uuid,p_id uuid,p_revision text,p_request uuid,p_action text,p_conversation uuid default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare a public.calendar_appointments; contact uuid; b jsonb; destination_channel uuid;
begin
 if auth.uid() is null or not public.fn_role_at_least(p_org,'agent') or not public.fn_support_write_allowed(p_org) then raise exception 'meet_forbidden' using errcode='42501';end if;
 if not public.fn_session_mfa_proven() then raise exception 'meet_mfa_required' using errcode='42501';end if;
 select contact_id into contact from public.calendar_appointments where organization_id=p_org and id=p_id;
 if contact is not null then perform public.fn_service_lock(p_org,contact);end if;
 select * into a from public.calendar_appointments where organization_id=p_org and id=p_id for update;
 if not found or a.owner_user_id is distinct from auth.uid() or not exists(select 1 from public.user_organizations where organization_id=p_org and user_id=auth.uid() and revoked_at is null) then raise exception 'meet_forbidden' using errcode='42501';end if;
 if a.revision::text is distinct from p_revision or a.meeting_request_id is distinct from p_request or a.status='cancelled' or a.location_kind<>'google_meet'
  or exists(select 1 from public.contacts where id=a.contact_id and organization_id=p_org and is_anonymized) then raise exception 'meet_stale' using errcode='PT409';end if;
 if p_action='retry' then
  if a.google_conflict is not null then raise exception 'google_conflict_requires_choice' using errcode='PT409';end if;
  if a.meeting_state='ready' then return false;end if;
  if a.meeting_state<>'failed' then
   update public.calendar_appointments set meeting_next_attempt_at=now(),google_next_attempt_at=now() where organization_id=p_org and id=p_id;return true;
  end if;
  -- Tempo/timeout não provam rejeição. Somente failure recebido gira solicitação.
  update public.calendar_appointments set meeting_request_id=case when meeting_last_error='google_failure' and meeting_received_at is not null then gen_random_uuid() else meeting_request_id end,
   meeting_requested_at=case when meeting_last_error='google_failure' and meeting_received_at is not null then null else meeting_requested_at end,
   meeting_received_at=case when meeting_last_error='google_failure' then null else meeting_received_at end,
   meeting_state='pending',meeting_attempts=0,meeting_last_error=null,meeting_next_attempt_at=now(),google_next_attempt_at=now() where organization_id=p_org and id=p_id;
 elsif p_action='deliver' then
  if a.contact_id is null then raise exception 'meet_conversation_unavailable' using errcode='42501';end if;
  select channel_session_id into destination_channel from public.conversations where organization_id=p_org and id=p_conversation and contact_id=a.contact_id and not is_group and public.fn_can_view_conversation(organization_id,assigned_to_user_id) for update;
  if not found then raise exception 'meet_conversation_unavailable' using errcode='42501';end if;
  b:=public.fn_service_boundary(p_org,p_conversation)-'status'-'demanda_fechada_em'-'service_started_at';
  if not public.fn_meet_boundary_current(b) then raise exception 'meet_conversation_stale' using errcode='PT409';end if;
  if a.meeting_delivery->'service_boundary'=b and a.meeting_delivery->>'channel_session_id'=destination_channel::text then
   if a.meeting_delivery->>'state' in ('waiting_for_link','sent') then return false;end if;
   if a.meeting_delivery->>'state'='queued' and a.meeting_delivery_job_id is not null then
    -- Recuperação humana de job morto conserva ledger/identidade. Não duplicar
    -- uma mensagem aceita antes do crash nem reconstruir fronteira antiga.
    update public.job_queue set status='pending',locked_by=null,locked_at=null,attempts=0,run_after=now(),last_error=null
     where organization_id=p_org and id=a.meeting_delivery_job_id and kind='transactional_delivery' and status in ('dead','failed','done');
    return found;
   end if;
  end if;
  update public.job_queue set status='failed',locked_by=null,locked_at=null,last_error='meet_delivery_superseded' where organization_id=p_org and id=a.meeting_delivery_job_id and kind='transactional_delivery' and status in ('pending','running');
  update public.calendar_appointments set meeting_delivery=jsonb_build_object('state','waiting_for_link','generation',gen_random_uuid(),'service_boundary',b,'authorized_by',jsonb_build_object('kind','user','id',auth.uid()),'source_operation_id',gen_random_uuid()),meeting_delivery_job_id=null where organization_id=p_org and id=p_id;
 else raise exception 'meet_action_invalid' using errcode='22023';end if;
 return true;
end;$$;

-- ---- reenviar o link do Meet é ação própria (migration 0365) ----
-- `p_action in ('deliver','resend')`, e o `return false` em estado enviado
-- passa a valer só para o `deliver` — ele é a proteção contra clique duplo, e
-- afrouxá-lo daria o reenvio tirando a proteção. `waiting_for_link`/`queued`
-- continuam trancando os dois. Corpo idêntico ao do bloco da 0363, com o ramo
-- do envio ampliado. Idempotente.
-- ⚠️ ENTRA ANTES DO BLOCO DA VARREDURA anon: ela cura só o que veio antes, e
-- função criada depois nasce exposta a `anon` e fica.
-- Recorte do PR #803, de @paulolimajr77.

create or replace function public.fn_meet_action(p_org uuid,p_id uuid,p_revision text,p_request uuid,p_action text,p_conversation uuid default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare a public.calendar_appointments; contact uuid; b jsonb; destination_channel uuid;
begin
 if auth.uid() is null or not public.fn_role_at_least(p_org,'agent') or not public.fn_support_write_allowed(p_org) then raise exception 'meet_forbidden' using errcode='42501';end if;
 if not public.fn_session_mfa_proven() then raise exception 'meet_mfa_required' using errcode='42501';end if;
 select contact_id into contact from public.calendar_appointments where organization_id=p_org and id=p_id;
 if contact is not null then perform public.fn_service_lock(p_org,contact);end if;
 select * into a from public.calendar_appointments where organization_id=p_org and id=p_id for update;
 if not found or a.owner_user_id is distinct from auth.uid() or not exists(select 1 from public.user_organizations where organization_id=p_org and user_id=auth.uid() and revoked_at is null) then raise exception 'meet_forbidden' using errcode='42501';end if;
 if a.revision::text is distinct from p_revision or a.meeting_request_id is distinct from p_request or a.status='cancelled' or a.location_kind<>'google_meet'
  or exists(select 1 from public.contacts where id=a.contact_id and organization_id=p_org and is_anonymized) then raise exception 'meet_stale' using errcode='PT409';end if;
 if p_action='retry' then
  if a.google_conflict is not null then raise exception 'google_conflict_requires_choice' using errcode='PT409';end if;
  if a.meeting_state='ready' then return false;end if;
  if a.meeting_state<>'failed' then
   update public.calendar_appointments set meeting_next_attempt_at=now(),google_next_attempt_at=now() where organization_id=p_org and id=p_id;return true;
  end if;
  -- Tempo/timeout não provam rejeição. Somente failure recebido gira solicitação.
  update public.calendar_appointments set meeting_request_id=case when meeting_last_error='google_failure' and meeting_received_at is not null then gen_random_uuid() else meeting_request_id end,
   meeting_requested_at=case when meeting_last_error='google_failure' and meeting_received_at is not null then null else meeting_requested_at end,
   meeting_received_at=case when meeting_last_error='google_failure' then null else meeting_received_at end,
   meeting_state='pending',meeting_attempts=0,meeting_last_error=null,meeting_next_attempt_at=now(),google_next_attempt_at=now() where organization_id=p_org and id=p_id;
 elsif p_action in ('deliver','resend') then
  if a.contact_id is null then raise exception 'meet_conversation_unavailable' using errcode='42501';end if;
  select channel_session_id into destination_channel from public.conversations where organization_id=p_org and id=p_conversation and contact_id=a.contact_id and not is_group and public.fn_can_view_conversation(organization_id,assigned_to_user_id) for update;
  if not found then raise exception 'meet_conversation_unavailable' using errcode='42501';end if;
  b:=public.fn_service_boundary(p_org,p_conversation)-'status'-'demanda_fechada_em'-'service_started_at';
  if not public.fn_meet_boundary_current(b) then raise exception 'meet_conversation_stale' using errcode='PT409';end if;
  if a.meeting_delivery->'service_boundary'=b and a.meeting_delivery->>'channel_session_id'=destination_channel::text then
   -- ⛔ ESTE `return false` É A PROTEÇÃO CONTRA CLIQUE DUPLO, e é por isso que o
   -- reenvio é uma AÇÃO NOVA em vez de um ramo reescrito. Ele impede a mesma
   -- mensagem de sair duas vezes por um clique nervoso; se o botão "Enviar de
   -- novo" apenas reescrevesse este ramo, ganharíamos o reenvio e perderíamos a
   -- proteção — e envio em dobro para cliente é pior que não-envio.
   -- `deliver` continua exatamente como era; `resend` passa reto, e quem o
   -- dispara já confirmou na tela.
   if p_action='deliver' and a.meeting_delivery->>'state' in ('waiting_for_link','sent') then return false;end if;
   if a.meeting_delivery->>'state'='queued' and a.meeting_delivery_job_id is not null then
    -- Recuperação humana de job morto conserva ledger/identidade. Não duplicar
    -- uma mensagem aceita antes do crash nem reconstruir fronteira antiga.
    update public.job_queue set status='pending',locked_by=null,locked_at=null,attempts=0,run_after=now(),last_error=null
     where organization_id=p_org and id=a.meeting_delivery_job_id and kind='transactional_delivery' and status in ('dead','failed','done');
    return found;
   end if;
  end if;
  update public.job_queue set status='failed',locked_by=null,locked_at=null,last_error='meet_delivery_superseded' where organization_id=p_org and id=a.meeting_delivery_job_id and kind='transactional_delivery' and status in ('pending','running');
  update public.calendar_appointments set meeting_delivery=jsonb_build_object('state','waiting_for_link','generation',gen_random_uuid(),'service_boundary',b,'authorized_by',jsonb_build_object('kind','user','id',auth.uid()),'source_operation_id',gen_random_uuid()),meeting_delivery_job_id=null where organization_id=p_org and id=p_id;
 else raise exception 'meet_action_invalid' using errcode='22023';end if;
 return true;
end;$$;

-- ---- o compromisso chega ao cliente mesmo sem Google Meet (migration 0366) ----
-- A exigência de link pronto passa a valer SÓ onde `location_kind='google_meet'`
-- nas TRÊS pontas: o gatilho que enfileira, o porteiro do envio e a ação que
-- autoriza. Nada mais muda. ⚠️ ANTES DA VARREDURA anon. Idempotente.
-- Recorte do PR #803, de @paulolimajr77.

create or replace function public.fn_meet_delivery_current(p_org uuid,p_job uuid,p_worker text,p_acquired_at timestamptz)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.job_queue j join public.calendar_appointments a on a.organization_id=j.organization_id and a.id::text=j.payload->>'appointment_id'
  join public.contacts c on c.organization_id=a.organization_id and c.id=a.contact_id
  join public.conversations v on v.organization_id=a.organization_id and v.contact_id=a.contact_id and v.id::text=j.payload->'service_boundary'->>'conversation_id'
  join public.channel_sessions cs on cs.organization_id=v.organization_id and cs.id=v.channel_session_id
  join public.organizations o on o.id=a.organization_id and o.status='active'
  where cs.archived_at is null and a.meeting_delivery->>'channel_session_id'=cs.id::text and j.organization_id=p_org and j.id=p_job and j.kind='transactional_delivery' and j.status='running' and j.locked_by=p_worker and j.locked_at=p_acquired_at
   and a.contact_id=j.contact_id and not c.is_anonymized and not c.is_blocked and a.status<>'cancelled' and (a.location_kind<>'google_meet' or (a.meeting_state='ready' and a.meeting_url is not null))
   and a.meeting_request_id::text=j.payload->>'meeting_request_id' and a.meeting_delivery->>'generation'=j.payload->>'delivery_generation'
   and a.meeting_delivery_job_id=j.id and a.meeting_delivery->>'state'='queued'
   and exists(select 1 from public.user_organizations where organization_id=p_org and user_id=a.owner_user_id and revoked_at is null)
   and (a.meeting_delivery->'authorized_by'->>'kind'='ai_agent' or
    (a.meeting_delivery->'authorized_by'->>'kind'='user' and a.meeting_delivery->'authorized_by'->>'id'=a.owner_user_id::text and exists(
     select 1 from public.user_organizations u where u.organization_id=p_org and u.user_id=a.owner_user_id and u.revoked_at is null and u.role in ('agent','manager','admin')
      and (u.role in ('manager','admin') or v.assigned_to_user_id=u.user_id or o.settings->>'visibility_mode'='all'
       or (coalesce(o.settings->>'visibility_mode','own_and_unassigned')='own_and_unassigned' and v.assigned_to_user_id is null)))))
   and a.meeting_delivery->'service_boundary'=j.payload->'service_boundary' and public.fn_meet_boundary_current(j.payload->'service_boundary'));
$$;
revoke all on function public.fn_meet_delivery_current(uuid,uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function public.fn_meet_delivery_current(uuid,uuid,text,timestamptz) to service_role;

create or replace function public.fn_meet_action(p_org uuid,p_id uuid,p_revision text,p_request uuid,p_action text,p_conversation uuid default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare a public.calendar_appointments; contact uuid; b jsonb; destination_channel uuid;
begin
 if auth.uid() is null or not public.fn_role_at_least(p_org,'agent') or not public.fn_support_write_allowed(p_org) then raise exception 'meet_forbidden' using errcode='42501';end if;
 if not public.fn_session_mfa_proven() then raise exception 'meet_mfa_required' using errcode='42501';end if;
 select contact_id into contact from public.calendar_appointments where organization_id=p_org and id=p_id;
 if contact is not null then perform public.fn_service_lock(p_org,contact);end if;
 select * into a from public.calendar_appointments where organization_id=p_org and id=p_id for update;
 if not found or a.owner_user_id is distinct from auth.uid() or not exists(select 1 from public.user_organizations where organization_id=p_org and user_id=auth.uid() and revoked_at is null) then raise exception 'meet_forbidden' using errcode='42501';end if;
 if a.revision::text is distinct from p_revision or a.meeting_request_id is distinct from p_request or a.status='cancelled'
  or exists(select 1 from public.contacts where id=a.contact_id and organization_id=p_org and is_anonymized) then raise exception 'meet_stale' using errcode='PT409';end if;
 if p_action='retry' then
  if a.google_conflict is not null then raise exception 'google_conflict_requires_choice' using errcode='PT409';end if;
  if a.meeting_state='ready' then return false;end if;
  if a.meeting_state<>'failed' then
   update public.calendar_appointments set meeting_next_attempt_at=now(),google_next_attempt_at=now() where organization_id=p_org and id=p_id;return true;
  end if;
  -- Tempo/timeout não provam rejeição. Somente failure recebido gira solicitação.
  update public.calendar_appointments set meeting_request_id=case when meeting_last_error='google_failure' and meeting_received_at is not null then gen_random_uuid() else meeting_request_id end,
   meeting_requested_at=case when meeting_last_error='google_failure' and meeting_received_at is not null then null else meeting_requested_at end,
   meeting_received_at=case when meeting_last_error='google_failure' then null else meeting_received_at end,
   meeting_state='pending',meeting_attempts=0,meeting_last_error=null,meeting_next_attempt_at=now(),google_next_attempt_at=now() where organization_id=p_org and id=p_id;
 elsif p_action in ('deliver','resend') then
  if a.contact_id is null then raise exception 'meet_conversation_unavailable' using errcode='42501';end if;
  select channel_session_id into destination_channel from public.conversations where organization_id=p_org and id=p_conversation and contact_id=a.contact_id and not is_group and public.fn_can_view_conversation(organization_id,assigned_to_user_id) for update;
  if not found then raise exception 'meet_conversation_unavailable' using errcode='42501';end if;
  b:=public.fn_service_boundary(p_org,p_conversation)-'status'-'demanda_fechada_em'-'service_started_at';
  if not public.fn_meet_boundary_current(b) then raise exception 'meet_conversation_stale' using errcode='PT409';end if;
  if a.meeting_delivery->'service_boundary'=b and a.meeting_delivery->>'channel_session_id'=destination_channel::text then
   -- ⛔ ESTE `return false` É A PROTEÇÃO CONTRA CLIQUE DUPLO, e é por isso que o
   -- reenvio é uma AÇÃO NOVA em vez de um ramo reescrito. Ele impede a mesma
   -- mensagem de sair duas vezes por um clique nervoso; se o botão "Enviar de
   -- novo" apenas reescrevesse este ramo, ganharíamos o reenvio e perderíamos a
   -- proteção — e envio em dobro para cliente é pior que não-envio.
   -- `deliver` continua exatamente como era; `resend` passa reto, e quem o
   -- dispara já confirmou na tela.
   if p_action='deliver' and a.meeting_delivery->>'state' in ('waiting_for_link','sent') then return false;end if;
   if a.meeting_delivery->>'state'='queued' and a.meeting_delivery_job_id is not null then
    -- Recuperação humana de job morto conserva ledger/identidade. Não duplicar
    -- uma mensagem aceita antes do crash nem reconstruir fronteira antiga.
    update public.job_queue set status='pending',locked_by=null,locked_at=null,attempts=0,run_after=now(),last_error=null
     where organization_id=p_org and id=a.meeting_delivery_job_id and kind='transactional_delivery' and status in ('dead','failed','done');
    return found;
   end if;
  end if;
  update public.job_queue set status='failed',locked_by=null,locked_at=null,last_error='meet_delivery_superseded' where organization_id=p_org and id=a.meeting_delivery_job_id and kind='transactional_delivery' and status in ('pending','running');
  update public.calendar_appointments set meeting_delivery=jsonb_build_object('state','waiting_for_link','generation',gen_random_uuid(),'service_boundary',b,'authorized_by',jsonb_build_object('kind','user','id',auth.uid()),'source_operation_id',gen_random_uuid()),meeting_delivery_job_id=null where organization_id=p_org and id=p_id;
 else raise exception 'meet_action_invalid' using errcode='22023';end if;
 return true;
end;$$;

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
  'delivery_generation',new.meeting_delivery->>'generation','service_boundary',b),now());
 update public.calendar_appointments set meeting_delivery_job_id=jid,meeting_delivery=meeting_delivery||'{"state":"queued"}'
  where organization_id=new.organization_id and id=new.id;
 return new;
end;$$;
revoke all on function public.fn_meet_delivery_enqueue() from public,anon,authenticated;



-- APÊNDICE 20260921030000_0368_redes_sociais_nativas.sql
-- Social connections reuse channel sessions, the inbox and the outbound ledger.
-- Credentials are server-only; tenant admins use authenticated API routes.
create table if not exists public.channel_integrations (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  profile_id text not null,
  credential_encrypted bytea not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.channel_integrations enable row level security;
revoke all on public.channel_integrations from public, anon, authenticated;
grant all on public.channel_integrations to service_role;
alter table public.contacts add column if not exists social_identity text;
-- A ficha MESCLADA fica de fora do índice: depois de juntar dois contatos, o
-- perdedor continua na tabela com `is_merged_into` apontando para o vencedor, e
-- os dois carregam a mesma identidade social. Sem esta guarda, a junção passa a
-- falhar com violação de unicidade — e quem junta é o operador, na tela.
create unique index if not exists contacts_org_social_identity_unique
  on public.contacts (organization_id, social_identity)
  where social_identity is not null and is_merged_into is null;
comment on column public.contacts.social_identity is
  'Opaque network/account/participant key. Never interpreted as a telephone or WhatsApp identity.';

-- As duas CHECKs de `channel_sessions` que o provider novo exige NÃO estão
-- aqui: elas ficam no bloco "provider zernio_social entra nos CHECKs"
-- (ABAIXO, logo antes da varredura de anon), porque precisam vir DEPOIS da
-- definição que o dump traz — a última definição é a que vale. Esta linha
-- afirmava o contrário ("incluídas no bloco único acima") e era falsa: o
-- apêndice não tocava constraint nenhuma, e toda VPS de cliente batia 23514 na
-- primeira conexão de rede social.
alter table public.conversations drop constraint if exists conversations_channel_check;
alter table public.conversations add constraint conversations_channel_check
  check (channel in ('whatsapp', 'instagram', 'facebook'));


-- APÊNDICE 20260921030100_0369_prospeccao_nativa.sql
-- Native prospecting is an adapter to discovery, CRM creation and existing AI delivery.
-- Server-only tables: authenticated routes resolve the tenant and authorize every command.
create table if not exists public.prospecting_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  credential_encrypted bytea not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.prospecting_campaigns (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  request_id uuid not null,
  name text not null,
  search jsonb not null,
  config jsonb,
  status text not null default 'draft' check (status in ('draft','running','paused','completed')),
  search_status text not null default 'starting' check (search_status in ('starting','running','succeeded','failed','unknown')),
  run_id text,
  dataset_id text,
  cost_usd numeric,
  result_count integer not null default 0,
  skipped_count integer not null default 0,
  error text,
  next_send_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, request_id)
);
create unique index if not exists prospecting_one_running_org on public.prospecting_campaigns(organization_id) where status='running';
create table if not exists public.prospecting_candidates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  campaign_id uuid not null,
  place_id text not null,
  phone text,
  data jsonb not null,
  status text not null default 'new' check (status in ('new','queued','sending','sent','skipped','failed')),
  contact_id uuid references public.contacts(id) on delete set null,
  lead_id uuid references public.crm_leads(id) on delete set null,
  conversation_id uuid references public.conversations(id) on delete set null,
  service_boundary jsonb,
  message_id uuid not null default gen_random_uuid(),
  attempted_at timestamptz,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, campaign_id) references public.prospecting_campaigns(organization_id,id) on delete cascade,
  unique (organization_id, place_id)
);
create unique index if not exists prospecting_phone_once_org on public.prospecting_candidates(organization_id,phone) where phone is not null;
create index if not exists prospecting_pending_campaign on public.prospecting_candidates(organization_id,campaign_id,status);
create index if not exists prospecting_conversation on public.prospecting_candidates(organization_id,conversation_id) where conversation_id is not null;
alter table public.prospecting_settings enable row level security;
alter table public.prospecting_campaigns enable row level security;
alter table public.prospecting_candidates enable row level security;
revoke all on public.prospecting_settings, public.prospecting_campaigns, public.prospecting_candidates from public, anon, authenticated;
grant all on public.prospecting_settings, public.prospecting_campaigns, public.prospecting_candidates to service_role;
notify pgrst, 'reload schema';

-- Migration 0370: native prospecting redaction and suppression
-- 0370: Redact discovery data through the canonical contact cascade.
-- Suppression tokens are pseudonymous, server-only and used exclusively to
-- refuse re-import. The API explicitly selects public fields and never exposes them.
alter table public.prospecting_candidates add column if not exists suppression_salt bytea;
alter table public.prospecting_candidates add column if not exists suppression_place bytea;
alter table public.prospecting_candidates add column if not exists suppression_phone bytea;
create index if not exists prospecting_suppressed_org
  on public.prospecting_candidates(organization_id) where suppression_salt is not null;

create or replace function public.fn_prospecting_refuse_erased_candidate()
returns trigger language plpgsql security definer
set search_path = public, extensions, pg_temp as $$
begin
  if exists (
    select 1 from public.prospecting_candidates p
    where p.organization_id = new.organization_id and p.suppression_salt is not null
      and (p.suppression_place = hmac(convert_to(new.place_id, 'UTF8'), p.suppression_salt, 'sha256')
        or (new.phone is not null and p.suppression_phone = hmac(convert_to(new.phone, 'UTF8'), p.suppression_salt, 'sha256')))
  ) then
    return null;
  end if;
  return new;
end;
$$;
revoke all on function public.fn_prospecting_refuse_erased_candidate() from public, anon, authenticated;
grant execute on function public.fn_prospecting_refuse_erased_candidate() to service_role;
drop trigger if exists prospecting_refuse_erased on public.prospecting_candidates;
create trigger prospecting_refuse_erased before insert on public.prospecting_candidates
  for each row execute function public.fn_prospecting_refuse_erased_candidate();

-- ---- as duas grafias do nono dígito, em UM lugar ----
--
-- Mesma regra de `lib/channels/phone-variants.ts`, e o SQL dela já existia
-- COPIADO dentro de `fn_aviso_de_caso_*`. Uma terceira cópia é como regra de
-- telefone diverge: alguém corrige uma e não sabe das outras. Aqui ela vira
-- função, e o expurgo de LGPD abaixo é o primeiro a consumi-la.
--
-- Por que comparar por VARIANTE e não pela string: o mesmo celular é gravado
-- com e sem o nono dígito por caminhos diferentes (cadastro à mão, importação,
-- o que o WhatsApp devolve). Comparar a string crua deixa a pessoa no banco
-- porque uma ponta tem um `9` a mais — e, em expurgo, não alcançar é violação.
--
-- A direção que REMOVE o nono confere o que sobra (`6-9` na primeira posição),
-- como o TypeScript faz: sem isso, um `9` grudado num fixo geraria o número
-- REAL de outra pessoa, e alcançar terceiro em expurgo é o erro oposto.
create or replace function public.fn_telefone_variantes(p_telefone text)
returns text[]
language sql
immutable
set search_path to 'public', 'pg_temp'
as $$
  with d as (select regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g') as v)
  select case
    when d.v = '' then array[]::text[]
    when d.v not like '55%' then array[d.v]
    when length(d.v) = 13
         and substring(d.v from 5 for 1) = '9'
         and substring(d.v from 6 for 1) between '6' and '9'
      then array[d.v, substring(d.v from 1 for 4) || substring(d.v from 6)]
    when length(d.v) = 12
         and substring(d.v from 5 for 1) between '6' and '9'
      then array[d.v, substring(d.v from 1 for 4) || '9' || substring(d.v from 5)]
    else array[d.v]
  end
  from d;
$$;
-- Função nova em `public` nasce alcançável pelas DUAS origens (o grant a PUBLIC
-- que o Postgres dá, e o default privilege do baseline para `anon`): as duas
-- saem, e só quem precisa entra.
revoke execute on function public.fn_telefone_variantes(text) from public, anon;
grant execute on function public.fn_telefone_variantes(text) to service_role;

CREATE OR REPLACE FUNCTION "public"."fn_lgpd_cascade_redact_contact"("p_organization_id" "uuid", "p_contact_id" "uuid", "p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions', 'pg_temp'
    AS $$
declare
  v_already bool;
  v_counts jsonb := '{}'::jsonb;
  v_media_paths text[] := '{}';
  v_anon_label text;
  v_count int;
  -- As grafias do telefone desta pessoa, capturadas ANTES de o passo 1 zerar
  -- `contacts.phone_number`. A ordem aqui não é detalhe: o expurgo da
  -- prospecção roda ~150 linhas depois do `update contacts`, e ler o telefone
  -- lá embaixo leria NULL — o braço por telefone existiria no código e não
  -- alcançaria linha nenhuma, que é pior que não existir, porque parece feito.
  v_variantes text[] := '{}';
begin
  perform public.fn_service_lock(p_organization_id,p_contact_id);
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

  -- Capturado AGORA, enquanto o telefone ainda existe (o passo 1 o apaga).
  select coalesce(public.fn_telefone_variantes(phone_number), '{}')
    into v_variantes
    from contacts
    where id = p_contact_id and organization_id = p_organization_id;

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
    -- O motivo CRU da última passagem (migration 0291). É código de
    -- vocabulário, não texto livre — mas ele diz que ESTA pessoa foi escalada
    -- por irritação, por assunto jurídico ou por suspeita de opt-out, e isso é
    -- um fato sobre ela. Entra NESTE update, e não num segundo: mesmo
    -- predicado, mesmas linhas, metade das varreduras.
    --
    -- ⚠️ `last_handoff_reason` é CHAVE DE NEGÓCIO em outro módulo: a ponte de
    -- voz limpa o silêncio filtrando pelo VALOR da coluna
    -- (`lib/wacalls/events-bridge.ts`). Zerá-la num contato anonimizado é
    -- seguro — não há chamada viva de contato anonimizado — e é a razão de
    -- esta entrega NÃO usar essa coluna para texto rico: ela continua
    -- recebendo só o código, e o texto vive em `passagens_de_atendimento`.
    last_handoff_reason = null,
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
  -- REAPLICADO AO DERIVAR ESTE APÊNDICE (merge da main, 0359 comanda).
  -- O Postgres troca o corpo INTEIRO num `create or replace`: um apêndice
  -- escrito sobre uma versão anterior da função APAGA, em silêncio, o passo
  -- que outra entrega acrescentou. Anonimizar devolveria SUCESSO com o texto
  -- da comanda ainda legível — e o SLA marcado como cumprido.
  -- 6b. sales — a comanda. PRESERVA valor, status e datas, e NÃO desliga o
  --     contato: a venda é registro financeiro (e fiscal) da organização, e
  --     desligá-la do contato faria o relatório por cliente deixar de fechar
  --     com o faturamento do período — divergência muda, meses depois, num
  --     número que ninguém consegue reconciliar. O contato apontado já é
  --     `Cliente Anonimizado #N`; o que sai daqui é o TEXTO LIVRE, que é onde
  --     a pessoa é nomeada de novo ("cliente da Ana, filha da Dona Maria").
  --     Os itens (`sale_items`) não entram: `description` ali é o nome do
  --     SERVIÇO, congelado na inclusão, e apagá-lo destruiria o relatório por
  --     serviço sem tirar dado de pessoa nenhum.
  update sales set
    notes = null,
    cancel_reason = case when cancel_reason is null then null else '[redigido]' end,
    reverse_reason = case when reverse_reason is null then null else '[redigido]' end,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('sales', v_count);

  -- 7. enqueue media for async deletion (idempotent via unique (bucket, object_path))
  if array_length(v_media_paths, 1) > 0 then
    insert into storage_redaction_queue (organization_id, request_id, bucket, object_path)
    select p_organization_id, p_request_id, 'whatsapp-media', path
      from unnest(v_media_paths) as path
      where path is not null and length(path) > 0
    on conflict (bucket, object_path) do nothing;
  end if;

  -- 7b. voice_calls — o TELEFONE de quem falou ao telefone (migration 0235).
  --
  -- `peer_phone` é `not null` e guarda o número da outra ponta: depois de
  -- anonimizar o contato, ele sobrevivia ligado ao `contact_id` e reidentificava
  -- a pessoa que pediu para ser esquecida. É o mesmo argumento que a foto de
  -- perfil já tinha (ver o bloco do avatar em `lib/lgpd/redact-cascade.ts`):
  -- anonimizar em toda parte menos numa é não ter anonimizado.
  --
  -- O que fica: direção, status, motivo do fim, marcas de tempo e duração. Um
  -- registro de "houve uma chamada de 12 minutos" sem número e sem dono não
  -- identifica ninguém e é o que sustenta a métrica do atendente e a fatura.
  -- `peer_phone` é NOT NULL, então recebe o rótulo, não `null`.
  update voice_calls set
    peer_phone = v_anon_label,
    owner_user_id = null,
    created_by = null,
    updated_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('voice_calls', v_count);

  -- Native discovery stores commercial/person data before the Inbox exists.
  -- Keep only keyed suppression tokens, restricted to the server, to prevent
  -- another extraction from reintroducing this erased candidate.
  --
  -- O PREDICADO ALCANÇA POR VÍNCULO **OU** POR TELEFONE, e o segundo braço é o
  -- que conserta um buraco real: quando o telefone raspado já pertencia a um
  -- contato conhecido da organização, `lib/prospecting/store.ts` grava o
  -- candidato como `skipped` e DEIXA `contact_id` nulo de propósito (lá o
  -- vínculo é o freio de mão do envio, em `worker.ts`). Só pelo `contact_id`,
  -- essa pessoa — justamente a que a empresa já conhece — pedia exclusão,
  -- recebia sucesso, a auditoria gravava `lgpd.redact_executed`, e o nome, o
  -- telefone e o endereço dela seguiam legíveis aqui.
  --
  -- Em expurgo os dois erros não têm o mesmo preço: alcançar demais custa um
  -- registro de prospecção descartado; alcançar de menos é violação legal. Por
  -- isso o `or`, e por isso a comparação por VARIANTE do nono dígito.
  update prospecting_candidates set suppression_salt = gen_random_bytes(32)
  where organization_id = p_organization_id
    and (contact_id = p_contact_id
         or (phone is not null
             and regexp_replace(phone, '\D', '', 'g') = any (v_variantes)))
    and suppression_salt is null;
  update prospecting_candidates set
    suppression_place = hmac(convert_to(place_id, 'UTF8'), suppression_salt, 'sha256'),
    suppression_phone = case when phone is null then null
      else hmac(convert_to(phone, 'UTF8'), suppression_salt, 'sha256') end,
    place_id = 'redacted:' || id::text,
    phone = null,
    data = jsonb_build_object('key', 'redacted:' || id::text,
      'name', v_anon_label, 'phone', null, 'website', null,
      'category', null, 'address', null, 'maps_url', null,
      'rating', null, 'reviews', null, 'emails', '[]'::jsonb, 'socials', '[]'::jsonb),
    status = 'skipped', service_boundary = null, error = null, updated_at = now()
  -- MESMO predicado do bloco anterior. Se os dois divergirem, a linha alcançada
  -- por um e não pelo outro fica com `suppression_salt` semeado e os dados
  -- pessoais intactos — um estado que parece tratado e não está.
  where organization_id = p_organization_id
    and (contact_id = p_contact_id
         or (phone is not null
             and regexp_replace(phone, '\D', '', 'g') = any (v_variantes)));
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('prospecting_candidates', v_count);


  -- agent_cases — o que a IA escreveu SOBRE a pessoa quando travou (migration 0280).
  --
  -- O caso é o texto que a equipe lê antes de decidir: `title`, `summary` e
  -- `blocker` saem do modelo a partir da conversa, e `context_snapshot` é o
  -- recorte dessa conversa que o motor mandou para ele. Nada disso é registro de
  -- operação — é o relato do problema de uma pessoa identificável, escrito por
  -- máquina. Sem este passo, anonimizar devolvia SUCESSO com o relato intacto.
  --
  -- As três colunas de texto são `not null`: recebem rótulo e texto fixo, nunca
  -- `null` (a mesma razão de `voice_calls.peer_phone` logo acima).
  --
  -- ⚠️ `updated_at` FICA FORA DO `set`, de propósito. O cobrador de caso parado
  -- (`app/api/v1/cron/case-stale-watcher/route.ts`) lê `updated_at` como "alguém
  -- da equipe encostou neste caso". A cascata não é alguém encostando: escrever
  -- ali faria a anonimização ADIAR a cobrança de um caso que continua parado, e
  -- o efeito só apareceria como um cliente esperando mais tempo.
  --
  -- O vínculo é pela CONVERSA porque `agent_cases` não tem FK para `contacts`.
  update agent_cases set
    title = v_anon_label,
    summary = '[resumo anonimizado]',
    blocker = '[bloqueio anonimizado]',
    context_snapshot = '{}'::jsonb
  where organization_id = p_organization_id
    and conversation_id in (
      select id from conversations
        where contact_id = p_contact_id and organization_id = p_organization_id
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_cases', v_count);

  -- agent_case_events — a linha do tempo do caso (migration 0280).
  --
  -- `body` é o que a pessoa da equipe escreveu ao responder o caso e o que o
  -- agente registrou sobre o que o LEAD respondeu; `metadata` carrega o recorte
  -- que o motor anexou. `kind`, `actor_kind`, `human_action` e `created_at`
  -- FICAM: são o registro de que houve um toque humano e quando — operação, não
  -- dado da pessoa, e é deles que sai a métrica de atendimento.
  update agent_case_events set
    body = null,
    metadata = '{}'::jsonb
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_events', v_count);

  -- demandas — o assunto do pedido (migration 0280).
  --
  -- `assunto` é texto livre sobre o que a pessoa pediu. O resto da linha é a
  -- operação da demanda (origem, estado, dono, prazo, desfecho) e fica de pé:
  -- apagar a linha inteira tiraria da organização a resposta a "quantos pedidos
  -- houve em março", que é o mesmo argumento do compromisso da agenda.
  --
  -- FK direta (`demandas.contact_id` é `not null`), então o vínculo é o contato.
  update demandas set
    assunto = null
  where organization_id = p_organization_id
    and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('demandas', v_count);

  -- agent_inbox_items — o aviso que leva o texto do caso para a Central (migration 0280).
  --
  -- O `body` do aviso de caso parado EMBUTE o título do caso
  -- (`app/api/v1/cron/case-stale-watcher/route.ts:128`), e o do handoff embute o
  -- motivo da parada (`lib/ai/handoff/orchestrator.ts:335`). Redigir o caso e
  -- deixar o aviso de pé seria anonimizar em toda parte menos numa — que é não
  -- ter anonimizado. O molde (resolver + trocar o corpo + soltar a referência) é
  -- o de `fn_meet_redact_contact`, que já faz isto para o aviso de compromisso.
  --
  -- ⚠️ O VÍNCULO É POLIMÓRFICO E TEM TRÊS BRAÇOS, não dois. Medido nos
  -- produtores, não suposto: `handoff` nasce com `ref_kind='contact'`
  -- (`lib/ai/handoff/orchestrator.ts:339`) E com `ref_kind='conversation'`
  -- (`lib/agent-engine/agent/inbound-turn.ts:4100`); `case_stale` nasce SEMPRE
  -- com `ref_kind='agent_case'` (a rota do cron acima, e a política em
  -- `lib/ai/inbox-destino.ts:38`). Um predicado com só os dois primeiros braços
  -- casa ZERO avisos de caso parado — e casar zero linha não é erro: é sucesso
  -- com o texto intacto.
  --
  -- Os `kind` são os MEDIDOS no CHECK vigente (`supabase/baseline.sql`, bloco
  -- único de `agent_inbox_items_kind_check`). `case_opened` NÃO existe, e kind
  -- inexistente num `in (...)` também casa zero e devolve sucesso. Para
  -- reconferir sem acreditar nesta prosa:
  --   grep -n "agent_inbox_items_kind_check check" -A40 supabase/baseline.sql
  update agent_inbox_items set
    status = 'resolved',
    resolved_at = now(),
    body = 'Contato anonimizado.',
    ref_id = null
  where organization_id = p_organization_id
    -- `aviso_de_caso_nao_entregue` (migration 0292) entra AQUI e não num
    -- passo próprio: é o mesmo predicado polimórfico, e o braço
    -- `ref_kind='agent_case'` já alcança o caso do titular. O corpo do aviso
    -- embute o título do caso, que é texto sobre a pessoa.
    and kind in ('handoff', 'case_stale', 'aviso_de_caso_nao_entregue')
    and (
      (ref_kind = 'contact' and ref_id = p_contact_id)
      or (ref_kind = 'conversation' and ref_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          ))
      or (ref_kind = 'agent_case' and ref_id in (
            select id from agent_cases
              where organization_id = p_organization_id
                and conversation_id in (
                  select id from conversations
                    where contact_id = p_contact_id and organization_id = p_organization_id
                )
          ))
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_inbox_items', v_count);

  -- agent_case_chat_messages — a consulta interna da equipe à IA SOBRE o caso
  -- (migration 0281). FK DIRETA para `contacts`, então o vínculo é o titular e
  -- não precisa passar pela conversa.
  --
  -- `redacted_at is null` no `where` é o que torna o passo IDEMPOTENTE: a
  -- varredura diária de redações incompletas roda a função de novo, e sem essa
  -- condição o carimbo de QUANDO se apagou seria reescrito a cada rodada.
  --
  -- A linha NÃO é apagada, só o texto: quem abrir o caso depois continua vendo
  -- que a equipe perguntou N vezes, quando, e se a IA respondeu. Apagar a linha
  -- inteira ficaria verde num teste de "o texto sumiu" e tiraria da organização
  -- a resposta a "quanto a equipe deliberou sobre este caso".
  update agent_case_chat_messages set
    body = null,
    redacted_at = now()
  where organization_id = p_organization_id
    and contact_id = p_contact_id
    and redacted_at is null;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('agent_case_chat_messages', v_count);

  -- passagens_de_atendimento — o BRIEFING é sobre a pessoa (migration 0291).
  --
  -- A linha guarda o que a IA concluiu sobre um atendimento de alguém
  -- identificável: o que ela entendeu que a pessoa quer (`title`), a narrativa
  -- que quem assumiu leu (`body`), as PALAVRAS LITERAIS do cliente (`notes`), o
  -- texto livre de quem passou (`content`) e o que a IA já tinha tentado
  -- (`tentativas`). Nada disso é registro de operação — é o relato do problema
  -- de uma pessoa, escrito por máquina, na tela de quem vai responder.
  --
  -- `body` é `not null` e recebe o RÓTULO, não `null` — a mesma razão de
  -- `voice_calls.peer_phone` e de `agent_cases.title` acima: coluna obrigatória
  -- anulada aborta o cascade INTEIRO, e um cascade abortado não anonimiza nada.
  --
  -- O que FICA, de propósito: `motor`, `origem`, `motivo_codigo`,
  -- `cliente_avisado`, `aviso_motivo_codigo`, `criado_em` e o par de
  -- reconhecimento. São operação — quantas passagens houve, por quê, quanto
  -- tempo até alguém assumir. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos atendimentos a IA devolveu em março, e quanto tempo esperaram".
  --
  -- O vínculo é a FK DIRETA `contact_id`: a tabela a carrega exatamente para
  -- este passo não precisar passar pela conversa.
  update passagens_de_atendimento set
    body       = v_anon_label,
    title      = null,
    notes      = null,
    content    = null,
    tentativas = '[]'::jsonb
  where organization_id = p_organization_id and contact_id = p_contact_id;
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('passagens_de_atendimento', v_count);

  -- entregas_de_aviso_de_caso — o registro do aviso ao suporte (migration 0292).
  --
  -- A tabela NÃO guarda o texto do aviso (só `corpo_hash`), e a única coluna
  -- capaz de ecoar um dado da pessoa é `erro_detalhe`: ali vai o texto CRU que
  -- o transporte devolveu, truncado, e um provedor que recusa um envio costuma
  -- devolver o destinatário dentro da mensagem de erro.
  --
  -- O que FICA, de propósito: `status`, `erro_codigo`, `tentativas`,
  -- `enviado_em`, `destino`, `corpo_hash`. São operação — quantos avisos saíram,
  -- quantos falharam e por quê. Um passo que apagasse a linha inteira ficaria
  -- verde num teste de "o texto sumiu" e tiraria da organização a resposta a
  -- "quantos avisos não chegaram em março". `destino` é o telefone da EQUIPE,
  -- não do titular: anonimizar um cliente não apaga o número do plantão.
  --
  -- ⚠️ PONTO CEGO DECLARADO: `tests/invariants/lgpd-cascata-alcanca-quem-
  -- guarda-pessoa.test.ts` só cobra tabela com FK para `contacts` E coluna cujo
  -- NOME case o padrão de PII. Esta tabela não satisfaz nenhuma das duas — o
  -- gate ficaria VERDE sem este passo. Ele entra porque é certo, não porque o
  -- gate cobra, e isto está escrito aqui para a próxima sessão não o remover
  -- achando que é ornamento. Quem o vigia é a catraca
  -- `tests/invariants/cascata-lgpd-nao-encolhe.test.ts`.
  --
  -- O vínculo é pela CONVERSA, como o de `agent_cases`: esta tabela aponta para
  -- o caso, e o caso não tem FK para `contacts`.
  update entregas_de_aviso_de_caso set
    erro_detalhe = null
  where organization_id = p_organization_id
    and case_id in (
      select id from agent_cases
        where organization_id = p_organization_id
          and conversation_id in (
            select id from conversations
              where contact_id = p_contact_id and organization_id = p_organization_id
          )
    );
  get diagnostics v_count = row_count;
  v_counts := v_counts || jsonb_build_object('entregas_de_aviso_de_caso', v_count);

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

-- Funções criadas depois da varredura abaixo poderiam nascer com EXECUTE para
-- anon por causa dos privilégios padrão do baseline. A definição precisa ficar
-- antes dela; o trigger só é instalado junto da tabela mais abaixo.
create or replace function public.touch_organization_data_plane_updated_at()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

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
  data_plane_provider text not null default 'supabase'
    check (data_plane_provider in ('supabase', 'postgresql')),
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
comment on column public.organization_data_planes.data_plane_provider is
  'Protocol and schema contract used by the dedicated plane; postgresql is promoted only after its operational baseline is installed.';
comment on column public.organization_data_planes.connection_uri_encrypted is
  'AES-256-GCM ciphertext; plaintext must never be returned to a browser or logged.';
alter table public.organization_data_planes enable row level security;
revoke all on public.organization_data_planes from anon, authenticated;
grant select, insert, update, delete on public.organization_data_planes to service_role;
create index if not exists organization_data_planes_status_idx
  on public.organization_data_planes(status);

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

