-- ====================================================================
-- OpenBSP - Instalação Completa no Schema 'openbsp' (Supabase Self-Hosted)
-- ====================================================================
-- Este script provisiona todo o ecossistema OpenBSP dentro do schema 'openbsp',
-- isolando completamente do schema 'public' do ClinicFlow para evitar conflitos
-- e economizar memória RAM na VPS.
-- ====================================================================

-- 1. Extensões essenciais
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS moddatetime SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS supabase_vault SCHEMA vault;

-- Schema auxiliar para logging de webhooks internos
CREATE SCHEMA IF NOT EXISTS supabase_functions;
CREATE TABLE IF NOT EXISTS supabase_functions.hooks (
  id bigserial PRIMARY KEY,
  hook_table_id oid NOT NULL,
  hook_name text NOT NULL,
  request_id bigint,
  created_at timestamptz DEFAULT now()
);

-- Permissões do Vault
GRANT USAGE ON SCHEMA vault TO postgres;
GRANT SELECT ON vault.decrypted_secrets TO postgres;

-- 2. Limpeza de resquícios de instalações parciais anteriores no schema 'openbsp'
-- (ATENÇÃO: Isso limpa SOMENTE o schema 'openbsp'. O schema 'public' do ClinicFlow fica intacto!)
DROP SCHEMA IF EXISTS openbsp CASCADE;
CREATE SCHEMA openbsp;

GRANT USAGE ON SCHEMA openbsp TO anon, authenticated, service_role, postgres;
GRANT ALL ON ALL TABLES IN SCHEMA openbsp TO anon, authenticated, service_role, postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA openbsp TO anon, authenticated, service_role, postgres;
GRANT ALL ON ALL ROUTINES IN SCHEMA openbsp TO anon, authenticated, service_role, postgres;

ALTER DEFAULT PRIVILEGES IN SCHEMA openbsp GRANT ALL ON TABLES TO anon, authenticated, service_role, postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA openbsp GRANT ALL ON SEQUENCES TO anon, authenticated, service_role, postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA openbsp GRANT ALL ON ROUTINES TO anon, authenticated, service_role, postgres;

-- 3. Bucket de Storage para Mídias (WhatsApp áudio, imagens, PDFs)
INSERT INTO storage.buckets (id, name, public)
VALUES ('media', 'media', true)
ON CONFLICT (id) DO NOTHING;

-- 4. Função nativa moddatetime no schema openbsp (independente de extensão C)
CREATE OR REPLACE FUNCTION openbsp.moddatetime() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW := jsonb_populate_record(NEW, jsonb_build_object(coalesce(TG_ARGV[0], 'updated_at'), now()));
  RETURN NEW;
END;
$$;

-- Configurar search_path temporário para a execução
SET search_path TO openbsp, public, extensions, vault, auth;



-- ------------------------------------------------------------
-- File: 01_types.sql
-- ------------------------------------------------------------


DO $$ BEGIN
  create type openbsp.service as enum (
  'whatsapp',
  'instagram',
  'local',
  'slack',
  'discord',
  'teams',
  'whatsapp-web',
  'tiktok'
);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  create type openbsp.webhook_operation as enum ('insert', 'update');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  create type openbsp.webhook_table as enum (
  'messages',
  'conversations',
  'organizations_addresses',
  'contacts_addresses',
  'logs'
);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  create type openbsp.role as enum ('owner', 'admin', 'member');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- ------------------------------------------------------------
-- File: 02_functions/02-01_json_utils.sql
-- ------------------------------------------------------------

-- JSON merge-patch, RFC 7396 (the same algorithm as SQLite's json_patch), with
-- one deliberate deviation: a non-object patch at the ROOT is ignored instead
-- of replacing the document. The RFC would let `extra = '"x"'` or `extra =
-- 'null'` blow the whole column away; these columns are always objects, and a
-- caller who writes a scalar into one has made a mistake, not a request.
--
-- | Patch value            | Behavior                               | Merges? |
-- |------------------------|----------------------------------------|---------|
-- | null                   | REMOVES the key (root null: ignored)   | n/a     |
-- | {} (empty object)      | Recursively merges (no-op if empty)    | YES     |
-- | Non-empty object       | Recursively merges nested keys         | YES     |
-- | Array                  | Replaces value at path                 | NO      |
-- | String/Number/Boolean  | Replaces value at path                 | NO      |
--
-- Arrays are opaque, exactly as in the RFC: {"tags":["a","b"]} patched with
-- {"tags":["c"]} yields {"tags":["c"]}. Element-wise array merge is not
-- expressible in merge-patch at all — there is no way to say "leave element 1
-- alone" — which is the same reason null has to mean removal.
create or replace function openbsp.merge_update_jsonb(target jsonb, path text[], object jsonb) returns jsonb
language plpgsql
immutable
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  key text;
  value jsonb;
begin
  if target is null then
    target := '{}'::jsonb;
  end if;

  case jsonb_typeof(object) -- object, array, string, number, boolean, and null
    when 'object' then
      if jsonb_typeof(target #> path) <> 'object' or target #> path is null then
          if cardinality(path) = 0 then
            target := '{}'::jsonb;
          else
            target := jsonb_set(target, path, '{}', true);
          end if;
      end if;

      for key, value in select * from jsonb_each(object) loop
          target := openbsp.merge_update_jsonb(target, array_append(path, key), value);
      end loop;
    when 'null' then
      -- The RFC's removal sentinel. Guarded rather than left to `#-`, which
      -- happens to return the target unchanged for an empty path: a
      -- root-level null falls under the deviation above and is ignored, and
      -- that should be stated, not inherited from an operator's edge case.
      if cardinality(path) > 0 then
        target := target #- path;
      end if;
    else
      -- Scalars and arrays replace. At the root this is where the deviation
      -- takes effect: jsonb_set with a zero-length path returns the target
      -- untouched, so the patch is dropped. A SQL NULL patch lands here too
      -- and propagates, jsonb_set being strict.
      target := jsonb_set(target, path, object, true);
  end case;

  return target;
end;
$$;

create or replace function openbsp.merge_update() returns trigger
language plpgsql
as $$
declare
  column_name text := tg_argv[0]::text;
  old_jsonb jsonb;
  new_jsonb jsonb;
  merged_value jsonb;
begin
  -- Get the column name from trigger argument
  if column_name is null or column_name = 'null' then
    raise exception 'column_name argument is missing';
  end if;

  -- Convert records to jsonb
  old_jsonb := to_jsonb(OLD);
  new_jsonb := to_jsonb(NEW);

  -- Get the column values and perform the merge
  merged_value := openbsp.merge_update_jsonb(
    old_jsonb -> column_name,
    '{}'::text[],
    new_jsonb -> column_name
  );

  -- Update NEW with the merged value
  new_jsonb := jsonb_set(new_jsonb, array[column_name], merged_value);

  -- Convert back to record
  NEW := jsonb_populate_record(NEW, new_jsonb);

  return NEW;
end;
$$;


-- ------------------------------------------------------------
-- File: 02_functions/02-02_edge_functions.sql
-- ------------------------------------------------------------

create or replace function openbsp.dispatcher_edge_function() returns trigger
language plpgsql
security definer
as $$
declare
  service text := new.service::text;
  path text := concat('/', service, '-dispatcher');
  request_id bigint;
  payload jsonb;
  base_url text;
  auth_token text;
  headers jsonb;
  timeout_ms integer := 10000;
begin
  if service = 'local' then
    update openbsp.messages set status = jsonb_build_object('delivered', now()) where id = new.id;

    return new;
  end if;

  select decrypted_secret into base_url from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into auth_token from vault.decrypted_secrets where name = 'edge_functions_token';
  
  headers = jsonb_build_object(
    'content-type', 'application/json',
    'authorization', 'Bearer ' || auth_token
  );
  
  payload = jsonb_build_object(
    'old_record', old,
    'record', new,
    'type', tg_op,
    'table', tg_table_name,
    'schema', tg_table_schema
  );

  select http_post into request_id from net.http_post(
    base_url || path,
    payload,
    '{}'::jsonb,
    headers,
    timeout_ms
  );

  insert into supabase_functions.hooks
    (hook_table_id, hook_name, request_id)
  values
    (tg_relid, tg_name, request_id);

  return new;
end;
$$;

create or replace function openbsp.edge_function() returns trigger
language plpgsql
security definer
as $$
declare
  request_id bigint;
  payload jsonb;
  base_url text;
  auth_token text;
  path text := tg_argv[0]::text;
  method text := tg_argv[1]::text;
  headers jsonb default '{}'::jsonb;
  params jsonb default '{}'::jsonb;
  timeout_ms integer := 10000;
begin
  if path is null or path = 'null' then
    raise exception 'path argument is missing';
  end if;

  if method is null or method = 'null' then
    raise exception 'method argument is missing';
  end if;

  if tg_argv[2] is null or tg_argv[2] = 'null' then
    select decrypted_secret into auth_token from vault.decrypted_secrets where name = 'edge_functions_token';

    headers = jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || auth_token
    );
  else
    headers = tg_argv[2]::jsonb;
  end if;

  if tg_argv[3] is null or tg_argv[3] = 'null' then
    params = '{}'::jsonb;
  else
    params = tg_argv[3]::jsonb;
  end if;

  select decrypted_secret into base_url from vault.decrypted_secrets where name = 'edge_functions_url';

  case
    when method = 'get' then
      select http_get into request_id from net.http_get(
        base_url || path,
        params,
        headers,
        timeout_ms
      );
    when method = 'post' then
      payload = jsonb_build_object(
        'old_record', old,
        'record', new,
        'type', tg_op,
        'table', tg_table_name,
        'schema', tg_table_schema
      );

      select http_post into request_id from net.http_post(
        base_url || path,
        payload,
        params,
        headers,
        timeout_ms
      );
    else
      raise exception 'method argument % is invalid', method;
  end case;

  insert into supabase_functions.hooks
    (hook_table_id, hook_name, request_id)
  values
    (tg_relid, tg_name, request_id);

  return new;
end
$$;

-- The internal mirror of edge_function('/agent-client', 'post'), for the
-- AI-DM flow (see handle_local_message_to_agent on messages). The trigger's
-- WHEN prefilters — local, a member author, armed — and the one fact a WHEN
-- cannot express lives here: is the other roster slot an AI agent?
--
-- A local direct's address IS its roster (agent ids, sorted, ':'-joined),
-- and RLS only allows roster edits on `group` — so "the AI answers where its
-- own id is in the address" is safe by construction: a member cannot pull
-- the AI into a real team conversation, and DMing the AI is not a mode, it
-- is just a conversation. Excluding the author (`a.id <> new.agent_id`) also
-- makes the AI's own replies a no-op here, with no special case. Everything
-- that enters and is not an AI DM — a group message, a human-human DM —
-- costs one indexed exists and exits.
create or replace function openbsp.local_message_to_agent() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  segments text[] := string_to_array(new.conversation_address, ':');
  base_url text;
  auth_token text;
  request_id bigint;
begin
  -- Two-member rosters only, for now: deleting this guard is the entire
  -- multi-party extension. Group/channel addresses are a single uuid and fail
  -- it too, and `is distinct from` keeps a peerless row (null address) out.
  if array_length(segments, 1) is distinct from 2 then
    return new;
  end if;

  if not exists (
    select 1 from openbsp.agents a
    where a.organization_id = new.organization_id
      and a.id::text = any (segments)
      and a.id <> new.agent_id
      and a.user_id is null
      and a.deleted_at is null
  ) then
    return new;
  end if;

  select decrypted_secret into base_url
  from vault.decrypted_secrets where name = 'edge_functions_url';
  select decrypted_secret into auth_token
  from vault.decrypted_secrets where name = 'edge_functions_token';

  select http_post into request_id from net.http_post(
    base_url || '/agent-client',
    jsonb_build_object(
      'old_record', old,
      'record', new,
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema
    ),
    '{}'::jsonb,
    jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || auth_token
    ),
    10000
  );

  insert into supabase_functions.hooks
    (hook_table_id, hook_name, request_id)
  values
    (tg_relid, tg_name, request_id);

  return new;
end
$$; 

-- ------------------------------------------------------------
-- File: 02_functions/02-03_trigger_functions.sql
-- ------------------------------------------------------------

-- Create local address and owner agent after org creation
create or replace function openbsp.after_insert_on_organizations() returns trigger
language plpgsql
security definer -- bypass RLS to create the first owner
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  user_id uuid := auth.uid();
  user_name text;
begin
  insert into openbsp.organizations_addresses (organization_id, service, address)
    values (new.id, 'local', new.id::text);

  if user_id is not null then
    select coalesce(raw_user_meta_data->>'full_name', email, '?') into user_name
    from auth.users
    where id = user_id;

    insert into openbsp.agents (organization_id, user_id, name, role)
    values (new.id, user_id, user_name, 'owner');
  end if;

  return new;
end;
$$;

-- See organizations_addresses.issue.
create or replace function openbsp.clear_address_issue() returns trigger
language plpgsql
as $$
begin
  new.issue := null;
  return new;
end;
$$;

-- A conversation's identity is its addressing, so none of it ever changes:
-- not the peer address, not the account (organization_address, service) the
-- conversation hangs off. Nothing legitimate needs it to: an ingestor upserts
-- on the identity index, and `local` mints the address at creation. Anything
-- that could move the address could also point a room it owns at two
-- colleagues' canonical roster, and make the DM between them impossible — the
-- identity index would already be taken. Freezing the account columns is also
-- what makes messages' insert-time addressing validation a permanent truth:
-- the parent can never drift out from under its rows.
--
-- `type` is immutable to API roles for a sharper reason: retyping a private
-- `direct` as `channel` publishes everyone else's messages to the whole
-- organization, and any one participant could do it with no role to stop them.
-- The service role keeps the write, because Slack really does convert a
-- private channel to a public one and the sync must follow.
--
-- RLS cannot express either: an UPDATE policy sees the old row in USING and
-- the new row in WITH CHECK, never both, so "this column may not change" has
-- to be a trigger. Same reason preserve_message_addressing exists.
create or replace function openbsp.preserve_conversation_addressing() returns trigger
language plpgsql
as $$
begin
  new.organization_id := old.organization_id;
  new.address := old.address;
  new.organization_address := old.organization_address;
  new.service := old.service;

  if current_role not in ('service_role', 'postgres', 'supabase_admin') then
    new.type := old.type;
  end if;

  return new;
end;
$$;

-- A deletion the deleted can undo is not a deletion. `members can update
-- themselves` is keyed on user_id = auth.uid() alone, so a removed member
-- reaches their own row and could otherwise clear deleted_at and restore every
-- access it revoked.
create or replace function openbsp.preserve_agent_deletion() returns trigger
language plpgsql
as $$
begin
  if current_role not in ('service_role', 'postgres', 'supabase_admin') then
    new.deleted_at := old.deleted_at;
  end if;

  return new;
end;
$$;

-- Prevent deletion of the last owner in an organization
create or replace function openbsp.prevent_last_owner_deletion() returns trigger
language plpgsql
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  owner_count int;
begin
  -- Skip check if org is being deleted (cascade delete)
  if not exists (
    select 1 from openbsp.organizations
    where id = old.organization_id
    for update skip locked
  ) then
    return old;
  end if;

  if old.role = 'owner' then
    -- An agents row IS a member (invitations are their own table), and an
    -- owner is a person: `user_id is not null`.
    select count(*) into owner_count
    from openbsp.agents
    where organization_id = old.organization_id
      and role = 'owner'
      and user_id is not null
      and deleted_at is null
      and id <> old.id;

    if owner_count = 0 then
      raise exception 'Cannot delete the last owner of an organization';
    end if;
  end if;

  return old;
end;
$$;

-- The other end of the same rule. agents_user_id_fkey is `on delete set null`,
-- so erasing an auth user leaves their agent rows standing but unclaimed —
-- and an unclaimed row stops counting as an owner, which can quietly leave an
-- organization with none. Guarding the agents table cannot catch it: nothing
-- is deleted there, a column is merely nulled.
--
-- So the refusal belongs here. An owner has to hand the organization over,
-- leave it, or delete it before their account can go. There is no account
-- deletion flow in the product today; this exists so that whichever one gets
-- built — including a click in the Supabase dashboard — cannot take an
-- organization down with it.
create or replace function openbsp.prevent_owner_user_deletion() returns trigger
language plpgsql
security definer -- bypass RLS: no policy applies to a user being erased
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  owned int;
begin
  select count(*) into owned
  from openbsp.agents
  where user_id = old.id
    and role = 'owner'
    and deleted_at is null;

  if owned > 0 then
    raise exception 'Cannot delete a user who still owns % organization(s)', owned
      using hint = 'transfer ownership, leave, or delete the organization first';
  end if;

  return old;
end;
$$;

-- Deleting an agent marks the row instead of removing it, for every agent —
-- hence its own trigger rather than a branch in the owner guard above, whose
-- WHEN clause narrows it to human owners.
--
-- An agent is referenced by things that outlive their membership: message
-- authorship, and — since local conversations are identified by their roster —
-- the very ADDRESS of every direct they are in. Removing the row
-- cascades away their participation while the address goes on naming them,
-- leaving a conversation that can never be repaired and a roster slot occupied
-- forever.
--
-- SECURITY DEFINER for two reasons: the caller has no UPDATE on someone else's
-- agent row, and preserve_agent_deletion would restore the old deleted_at for
-- any non-privileged role — including the member deleting themselves.
--
-- The same organizations probe as above: during an organization cascade the
-- parent row is locked, SKIP LOCKED finds nothing, and the delete is allowed
-- through — otherwise a suppressed cascade would leave the FK unsatisfiable
-- and the organization undeletable.
create or replace function openbsp.mark_agent_deleted() returns trigger
language plpgsql
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
begin
  if not exists (
    select 1 from openbsp.organizations
    where id = old.organization_id
    for update skip locked
  ) then
    return old;
  end if;

  update openbsp.agents
  set deleted_at = coalesce(deleted_at, now())
  where id = old.id;

  return null;
end;
$$;

-- SECURITY DEFINER because this is now the ONLY way a conversation gets
-- created for a mirror service: 05-03 grants INSERT on conversations to API
-- roles for `local` alone, so a member starting a WhatsApp chat does it by
-- inserting the first message and letting this trigger mint the row. The
-- elevation cannot be used to reach a conversation the caller may not see —
-- the messages WITH CHECK policy runs after BEFORE triggers, so it re-tests
-- visibility against the conversation_id this function just resolved.
create or replace function openbsp.before_insert_on_messages() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  _conv record;
begin
  -- The addressing, in two columns:
  --
  -- sender_address is a contact reference or null: the peer who authored the
  -- message (a phone/BSUID, a Slack workspace member — ties to
  -- contacts_addresses), or null when the account itself spoke. Deliverable
  -- vs record-only is decided by status.pending + content.internal, not by
  -- authorship (see the dispatch trigger).
  -- conversation_address is the peer the conversation is with.

  -- Internal rows (tool traces, agent errors) are record-only and are born
  -- unarmed by their writer: agent-client — the one client that writes them —
  -- inserts them with status {}. pending is the declared arm bit, and not
  -- carrying it is also how history-synced rows pass through without waking
  -- any automation.

  -- If conversation_id is stated, the conversation is the authority on the
  -- denormalized addressing: fill what the writer omitted, refuse what they
  -- misstated. These columns are load-bearing at dispatch time — the peer
  -- address is the recipient, organization_address picks the account and its
  -- token, service picks the dispatcher — so drift here is a message to the
  -- wrong place. Together with the update-time freezes (both preserve_*
  -- triggers) this gives the composite-FK guarantee for one PK lookup,
  -- without widening the messages indexes to a four-column text key.
  if new.conversation_id is not null then
    select c.organization_id, c.service, c.organization_address, c.address
    into _conv
    from openbsp.conversations c
    where c.id = new.conversation_id;

    if not found then
      raise exception 'Conversation % does not exist', new.conversation_id;
    end if;

    if new.organization_id is null then
      new.organization_id := _conv.organization_id;
    elsif new.organization_id <> _conv.organization_id then
      raise exception 'organization_id % disagrees with the conversation''s %',
        new.organization_id, _conv.organization_id;
    end if;

    if new.service is null then
      new.service := _conv.service;
    elsif new.service <> _conv.service then
      raise exception 'service % disagrees with the conversation''s %',
        new.service, _conv.service;
    end if;

    if new.organization_address is null then
      new.organization_address := _conv.organization_address;
    elsif new.organization_address <> _conv.organization_address then
      raise exception 'organization_address % disagrees with the conversation''s %',
        new.organization_address, _conv.organization_address;
    end if;

    if new.conversation_address is null then
      new.conversation_address := _conv.address;
    elsif new.conversation_address <> _conv.address then
      raise exception 'conversation_address % disagrees with the conversation''s %',
        new.conversation_address, _conv.address;
    end if;

    return new;
  end if;

  -- Look up conversation_id. A conversation IS a channel, so this is an exact
  -- hit on conversations_identity_idx — the key is unique, no most-recent
  -- tiebreak.
  --
  -- organization_id is in the predicate so the scan can start from the index's
  -- leading column. Plain equality throughout: conversation_address is never
  -- null here, and equality (unlike `is not distinct from`) is indexable.
  --
  -- A peerless (local) message with neither conversation_id nor
  -- conversation_address matches nothing and falls through to the insert
  -- below, where the conversations trigger mints an id for it.
  if new.conversation_address is not null then
    select id into new.conversation_id
    from openbsp.conversations
    where organization_id = new.organization_id
      and service = new.service
      and organization_address = new.organization_address
      and address = new.conversation_address;
  end if;

  -- Create conversation if it doesn't exist. Two messages for a peer nobody
  -- has spoken to yet can arrive at once — a webhook batch, or two batches in
  -- flight — and both find nothing above, so the insert has to survive losing
  -- that race rather than raise on conversations_identity_idx. `do nothing`
  -- returns no row when the other writer won; read its id back instead.
  --
  -- A peerless (local) conversation_address is null, which is distinct from
  -- itself in a unique index, so that path never conflicts and always mints.
  if new.conversation_id is null then
    insert into openbsp.conversations (
      organization_id,
      organization_address,
      address,
      service
    ) values (
      new.organization_id,
      new.organization_address,
      new.conversation_address,
      new.service
    )
    on conflict (organization_id, organization_address, service, address)
    do nothing
    returning id into new.conversation_id;

    if new.conversation_id is null then
      select id into new.conversation_id
      from openbsp.conversations
      where organization_id = new.organization_id
        and service = new.service
        and organization_address = new.organization_address
        and address = new.conversation_address;
    end if;
  end if;

  return new;
end;
$$;

-- BEFORE UPDATE: a message's addressing is set at insert — where
-- before_insert_on_messages validates it against the conversation — and never
-- changes: not the conversation reference, not the denormalized account and
-- peer columns it was validated with. sender_address may be FILLED (null →
-- the actual author) but never flipped — the Slack echo of a send from
-- OpenBSP updates the dispatched row (sender null) with the member who sent
-- it, while an Instagram self-message echo landing on an already-attributed
-- row cannot rewrite it. Updates otherwise only merge content/status.
create or replace function openbsp.preserve_message_addressing() returns trigger
language plpgsql
as $$
begin
  new.sender_address := coalesce(old.sender_address, new.sender_address);
  new.organization_id := old.organization_id;
  new.conversation_id := old.conversation_id;
  new.conversation_address := old.conversation_address;
  new.organization_address := old.organization_address;
  new.service := old.service;

  return new;
end;
$$;

-- BEFORE UPDATE, ahead of the content merge: a medium and its placeholder can
-- land on the same row in either order — the Cloud API's history sync replays
-- a media message as a media_placeholder and sends the asset on its own, and
-- whichever arrives second patches the first. A stored file always wins. A
-- placeholder landing on a row that holds a file leaves the content as it is
-- (the caption is the same on both); a file landing on a placeholder drops the
-- placeholder's `data`, which a FilePart does not carry.
create or replace function openbsp.keep_stored_media() returns trigger
language plpgsql
as $$
begin
  if new.content->>'kind' = 'media_placeholder'
    and old.content->'file'->>'uri' is not null then
    new.content := old.content;
  elsif new.content->>'type' = 'file' and old.content ? 'data' then
    new.content := new.content || '{"data": null}'::jsonb;
  end if;

  return new;
end;
$$;

-- AFTER trigger: a synced REMOVE dropped the entry from the service's address
-- book — delete the row too, unless a conversation still references the
-- address. The conversation's address equals the contact's exactly on direct
-- chats — the only shape a contact entry describes.
create or replace function openbsp.cleanup_removed_address_if_empty() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from openbsp.conversations c
    where c.organization_id = new.organization_id
      and c.organization_address = new.organization_address
      and c.service = new.service
      and c.address = new.address
  ) then
    delete from openbsp.contacts_addresses
    where organization_id = new.organization_id
      and organization_address = new.organization_address
      and service = new.service
      and address = new.address;
  end if;

  return null;
end;
$$;

-- Writes the participants of a `local` conversation.
--
-- `local` is the one service where a member creates the conversation directly
-- (05-03 grants INSERT for it alone), and the one whose visibility is decided
-- purely by shape: a `channel` is org-wide, everything else is participants
-- only. So without these rows the member who just created a conversation could
-- not see it.
--
-- Where the participants come from depends on the shape, and it is the same
-- split as the address (before_insert_on_conversations):
--
--   direct          The roster IS the identity, so it is read straight back
--                   out of the canonical address — which is why a direct is
--                   always roster-addressed, including a note to self. Fixed
--                   here, for good: 05-12 grants no member insert or delete
--                   for it, because changing who is in one would make it a
--                   different conversation.
--   group, channel  Membership is mutable and starts with the creator alone;
--                   everyone else arrives through 05-12.
--
-- SECURITY DEFINER: conversations_agents is service-managed for the shapes
-- that matter (05-12), so the caller has no INSERT of their own here. A
-- service-role or API-key insert has no auth.uid() and so no creator to
-- record — for group/channel that yields a conversation nobody is in (see
-- TODO).
create or replace function openbsp.after_insert_on_local_conversation() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into openbsp.conversations_agents (
    organization_id,
    service,
    organization_address,
    conversation_id,
    agent_id
  )
  select
    new.organization_id,
    new.service,
    new.organization_address,
    new.id,
    a.id
  from openbsp.agents a
  where a.organization_id = new.organization_id
    and case
      when new.type = 'direct'
      then a.id::text = any (string_to_array(new.address, ':'))
      else a.user_id = auth.uid()
    end
  on conflict do nothing;

  return new;
end;
$$;

create or replace function openbsp.before_insert_on_conversations() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  _declared text[];
  _unknown text[];
  _roster uuid[];
  _caller uuid;
begin
  -- `local` addresses itself, in one of two ways, and the client chooses by
  -- stating a type:
  --
  --   group / channel   A named container whose membership changes. Identity
  --                     is its own; it gets the row's id, further down.
  --   anything else     A ROSTER. The client says who is in it ('A:B:C', any
  --                     order) and this canonicalises to sorted agent ids.
  --                     That canonical form IS the identity, so the unique
  --                     index answers "does this conversation already exist
  --                     between these people" with a conflict — a pair and a
  --                     party of eight are the same shape: `direct`.
  --
  -- The author is always in the room they open, so it is added rather than
  -- demanded: you cannot start a conversation you are not in, and omitting the
  -- address entirely is then just a roster of one — a note to self, which is
  -- what the UI's "new conversation" has always produced. One of those per
  -- member, for the same reason there is one DM per pair.
  if new.service = 'local'
    and (new.type is null or new.type = 'direct')
  then
    -- Null for the service role, which has no agent of its own; a roster it
    -- states is taken as given.
    select a.id into _caller
    from openbsp.agents a
    where a.organization_id = new.organization_id
      and a.user_id = auth.uid();

    _declared := array_remove(
      coalesce(string_to_array(new.address, ':'), '{}'), ''
    );

    if _caller is not null then
      _declared := _declared || _caller::text;
    end if;

    -- Named before resolved, so the error can say WHICH id failed. Every
    -- malformed roster arrives here: a stranger's id, an agent of another
    -- organization, an uppercased uuid (agent ids render lowercase), a word
    -- that is not a uuid at all.
    _unknown := array(
      select distinct d
      from unnest(_declared) d
      where not exists (
        select 1 from openbsp.agents a
        where a.organization_id = new.organization_id and a.id::text = d
      )
    );

    if array_length(_unknown, 1) is not null then
      raise exception 'Roster names %, not an agent of this organization',
        array_to_string(_unknown, ', ');
    end if;

    -- distinct: naming someone twice is a typo, not a bigger room.
    select array_agg(distinct a.id order by a.id) into _roster
    from openbsp.agents a
    where a.organization_id = new.organization_id
      and a.id::text = any (_declared);

    if _roster is not null then
      new.address := array_to_string(_roster, ':');
      new.type := 'direct';
    end if;
  end if;

  -- A named container is identified by ITSELF, so its address is not the
  -- client's to choose. A supplied address could name the canonical roster of
  -- two other people — a `group` addressed 'B:C' would occupy the identity
  -- index and make the DM between B and C impossible forever, while neither
  -- could see or delete the row holding it.
  if new.service = 'local' and new.type in ('group', 'channel') then
    new.address := new.id::text;
  end if;

  -- A conversation minted without a stated shape is 1:1 — that is what an
  -- inbound message from an unknown peer means, and it is the only shape
  -- WhatsApp Cloud and Instagram have. Connectors that know better state it
  -- before the message lands (generic-webhook, for whatsapp-web group JIDs and
  -- broadcast lists).
  --
  -- `slack` is exempt: its ingestor classifies asynchronously and relies on a
  -- null meaning "ask conversations.info again", which a default would erase.
  if new.type is null and new.service <> 'slack' then
    new.type := 'direct';
  end if;

  -- Conversations with external services must have a peer.
  if new.service <> 'local' and new.address is null then
    raise exception 'Conversations with external services require an address';
  end if;

  -- A `local` group or channel is identified by itself, not by who is in it,
  -- so it addresses itself: the conversation's own id. Column defaults are
  -- applied before BEFORE-INSERT triggers run, so new.id is already there.
  -- Keeping the column NOT NULL is what lets the identity index be a plain
  -- unique constraint rather than one whose behaviour depends on NULL
  -- semantics.
  if new.address is null then
    new.address := new.id::text;
  end if;

  -- No contact bootstrap: writers manage contacts_addresses themselves
  -- (the address is a soft reference by design).
  return new;
end;
$$;

-- The invitee is the one row shape in the schema that reads a table it has no
-- access to: 05-13 hands them their own pending invitations and nothing else,
-- while organizations (05-00) and agents (05-04) are member-only — they are
-- not a member yet, that being the point. So the banner can name an email and
-- a role, and cannot say WHICH organization or WHO asked.
--
-- These three columns answer that without opening either table. They are a
-- snapshot of what the offer says, and the writer has no say in them: any
-- stated value is discarded and replaced with the authority's. Insert AND
-- update, because the invitee has no way to check the text — a writer-stated
-- name would be a phishing field ("join Acme Payroll") rather than a
-- denormal, and re-deriving on every write is what makes restating one
-- pointless. It also carries a rename through to offers still open.
--
-- SECURITY DEFINER for the email: auth.users is granted to no API role.
create or replace function openbsp.before_insert_or_update_on_invitations() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select o.name into new.organization_name
  from openbsp.organizations o
  where o.id = new.organization_id;

  -- Scoped to the invitation's own organization: invitations_invited_by_fkey
  -- points at agents(id) alone, so nothing stops an owner from naming an
  -- agent in someone else's tenant, and copying that name here would be the
  -- one place it becomes readable. A mismatch leaves both columns null —
  -- `select into` assigns null when no row is found.
  select a.name, u.email
  into new.invited_by_name, new.invited_by_email
  from openbsp.agents a
  left join auth.users u on u.id = a.user_id
  where a.id = new.invited_by
    and a.organization_id = new.organization_id;

  return new;
end;
$$;

create or replace function openbsp.notify_webhook() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  webhook_record record;
  headers jsonb;
begin
  -- loop through all matching webhooks
  for webhook_record in
    select w.url, w.token
    from openbsp.webhooks w
    where new.organization_id = w.organization_id
      and w.table_name = tg_table_name::openbsp.webhook_table
      and lower(tg_op)::openbsp.webhook_operation = any(w.operations)
    limit 3
  loop
    -- prepare headers
    headers := case
      when webhook_record.token is not null then
        jsonb_build_object(
          'content-type', 'application/json',
          'authorization', 'Bearer ' || webhook_record.token
        )
      else
        jsonb_build_object(
          'content-type', 'application/json'
        )
      end;

    -- send webhook notification
    perform net.http_post(
      url := webhook_record.url,
      body := jsonb_build_object(
        'data', to_jsonb(new),
        'entity', tg_table_name,
        'action', lower(tg_op)
      ),
      headers := headers
    );
  end loop;

  return new;
end;
$$;


-- ------------------------------------------------------------
-- File: 02_functions/02-04_rcp_functions.sql
-- ------------------------------------------------------------

create or replace function openbsp.init_data(
  p_organization_id uuid,
  p_limit integer default 200,
  p_per_conversation integer default 10,
  p_since timestamptz default null,
  p_until timestamptz default null
)
returns json
language plpgsql
stable
security invoker
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  _messages json;
  _conversations json;
  _conversation_ids uuid[];
begin
  -- Up to p_per_conversation messages per conversation, p_limit in total,
  -- newest first.
  --
  -- Driven from conversations, never by ranking the org's messages: every
  -- returned message belongs to one of the p_limit conversations with the
  -- newest message (each of those contributes its own newest, which outranks
  -- anything from a conversation further down). So it costs one index probe
  -- per conversation plus p_limit short ones on messages_org_conv_timestamp_idx.
  -- A window over the org's messages reads every row it has, and at 64k
  -- messages that runs past the statement timeout.
  with latest as (
    select c.id, lm.timestamp
    from openbsp.conversations c
    cross join lateral (
      select m.timestamp
      from openbsp.messages m
      where m.organization_id = c.organization_id
        and m.conversation_id = c.id
        and (p_since is null or m.timestamp > p_since)
        and (p_until is null or m.timestamp < p_until)
      order by m.timestamp desc
      limit 1
    ) lm
    where c.organization_id = p_organization_id
    order by lm.timestamp desc
    limit p_limit
  ),
  limited as (
    select m.*
    from latest l
    cross join lateral (
      select m.*
      from openbsp.messages m
      where m.organization_id = p_organization_id
        and m.conversation_id = l.id
        and (p_since is null or m.timestamp > p_since)
        and (p_until is null or m.timestamp < p_until)
      order by m.timestamp desc
      limit p_per_conversation
    ) m
    order by m.timestamp desc
    limit p_limit
  )
  select
    coalesce(json_agg(row_to_json(l.*)), '[]'::json),
    array_agg(distinct l.conversation_id)
  into _messages, _conversation_ids
  from limited l;

  -- Fetch conversations for the messages returned
  select coalesce(json_agg(row_to_json(c.*)), '[]'::json)
  into _conversations
  from openbsp.conversations c
  where c.id = any(_conversation_ids);

  return json_build_object(
    'conversations', _conversations,
    'messages', _messages
  );
end;
$$;


-- ------------------------------------------------------------
-- File: 02_functions/02-05_text_limits.sql
-- ------------------------------------------------------------

-- The longest text a service sends in one message, in characters: a text
-- message's text (type 'text') or a file's caption (type 'file'). Null where
-- the service sets none we enforce (local, discord, teams), and for data
-- parts, whose text is not what is sent.
--
-- Instagram and TikTok attachments have no caption, so their dispatchers send
-- it as a text after the file, and it takes the text limit. Slack truncates
-- past its limit rather than refusing.
--
-- Clients ask it to split what they write; the limit_text_length trigger holds
-- every outgoing row to it.
create or replace function openbsp.text_limit(service openbsp.service, type text)
returns integer
language sql
immutable
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  select case
    when type not in ('text', 'file') then null
    else case service
      when 'whatsapp' then case type when 'file' then 1024 else 4096 end
      when 'instagram' then 1000
      when 'tiktok' then 6000
      when 'slack' then 40000
      when 'whatsapp-web' then 65536
    end
  end;
$$;

-- What is dispatched is the row as written, never a cut or a split of it: a
-- text longer than its service sends is refused here, at insert, where the
-- writer can still split it, rather than failing at dispatch.
create or replace function openbsp.limit_text_length() returns trigger
language plpgsql
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  _limit integer := openbsp.text_limit(new.service, new.content->>'type');
  _length integer := char_length(new.content->>'text');
begin
  if _length > _limit then
    raise exception using
      errcode = 'check_violation',
      message = format(
        '%s is %s characters long; %s sends at most %s',
        case new.content->>'type' when 'file' then 'The caption' else 'The text' end,
        _length, new.service, _limit
      ),
      hint = 'Split it into several messages.';
  end if;

  return new;
end;
$$;


-- ------------------------------------------------------------
-- File: 03_models/03-00_organizations.sql
-- ------------------------------------------------------------

create table openbsp.organizations (
  id uuid default gen_random_uuid() not null,
  name text not null,
  extra jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.organizations
add constraint organizations_pkey
primary key (id);

create trigger handle_new_organization
after insert
on openbsp.organizations
for each row
execute function openbsp.after_insert_on_organizations();

create trigger set_extra
before update
on openbsp.organizations
for each row
when (
  new.extra is not null
)
execute function openbsp.merge_update('extra');

create trigger set_updated_at
before update
on openbsp.organizations
for each row
execute function openbsp.moddatetime('updated_at');


-- ------------------------------------------------------------
-- File: 03_models/03-01_organizations_addresses.sql
-- ------------------------------------------------------------

create table openbsp.organizations_addresses (
  organization_id uuid not null,
  service openbsp.service not null,
  address text not null,
  -- Owner of a personal account (e.g. a member's Slack identity). null =
  -- ownerless: for customer-facing services that means org-wide (the shared
  -- inbox); for intra-org services (slack) nothing is ever org-wide — the
  -- ownerless workspace anchor's conversations are visible to their
  -- members only (see is_conversation_visible). The FK to agents is declared
  -- in 03-04_agents.sql because agents is created after this table.
  agent_id uuid,
  extra jsonb,
  status text default 'connected'::text not null,
  -- What the service broke, when it was the service and not a member: the UI
  -- warns, and whoever can reconnect the account gets an email. null while
  -- the account works, and after a member disconnects it themselves.
  -- { reason, until?: ISO, detail?: text } — reason is one of:
  --   logged_out  WhatsApp unlinked the device (WhatsApp Web)
  --   banned      the number or account was barred; a ban that says when it
  --               lifts carries `until`
  --   expired     the token died
  --   removed     our access was taken away at the provider (unshared, app
  --               uninstalled, deauthorized)
  --   offboarded  a coexistence number stopped sharing with the API
  --   deleted     the number or its account no longer exists
  --   violation   Meta reported a policy violation
  --   restricted  Meta limited what the account may do for a while
  --               (`until`), e.g. starting conversations
  --   locked      Meta refused to send because the account is locked
  -- `detail` is the provider's own word for it, e.g. a violation's type
  -- (SCAM). Usually on a disconnected row; a token that died, a restriction
  -- and a lock keep theirs connected, since messages still arrive and the
  -- account keeps its place under the connections cap. An issue whose `until`
  -- has passed is over: it warns of nothing, and stays until the account
  -- reconnects or a new issue replaces it.
  issue jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

-- service is part of the key, exactly as in contacts_addresses: one canonical
-- address string can name accounts on two services (bare phone digits are both
-- a 'whatsapp' and a 'whatsapp-web' account), and they are separate
-- connections with separate tokens.
--
-- It is also what lets every dependent FK carry service, so a child row can
-- never claim a service its account does not have.
alter table only openbsp.organizations_addresses
add constraint organizations_addresses_pkey
primary key (organization_id, service, address);

alter table only openbsp.organizations_addresses
add constraint organizations_addresses_issue_reason
check (
  issue is null
  or issue->>'reason' in (
    'logged_out',
    'banned',
    'expired',
    'removed',
    'offboarded',
    'deleted',
    'violation',
    'restricted',
    'locked'
  )
);

alter table only openbsp.organizations_addresses
add constraint organizations_addresses_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

create trigger set_extra
before update
on openbsp.organizations_addresses
for each row
when (
  new.extra is not null
)
execute function openbsp.merge_update('extra');

-- An account connected again has nothing left to warn about, whichever path
-- brought it back.
create trigger clear_issue
before update
on openbsp.organizations_addresses
for each row
when (
  old.status <> 'connected' and new.status = 'connected'
)
execute function openbsp.clear_address_issue();

create trigger set_updated_at
before update
on openbsp.organizations_addresses
for each row
execute function openbsp.moddatetime('updated_at');

-- An account's first issue is an email to whoever can reconnect it. Only the
-- first: one that worsens (a violation, then the ban that follows it moments
-- later) or is flagged again stays quiet until the account is reconnected and
-- the issue cleared, or the issue it replaces is over.
create trigger notify_address_issue
after update
on openbsp.organizations_addresses
for each row
when (
  new.issue is not null
  and new.issue is distinct from old.issue
  and (old.issue is null or (old.issue->>'until')::timestamptz < now())
)
execute function openbsp.edge_function('/notifications', 'post');

create trigger z_notify_webhook_organizations_addresses
after insert or update
on openbsp.organizations_addresses
for each row
execute function openbsp.notify_webhook();

create index organizations_addresses_agent_id_idx
on openbsp.organizations_addresses
using btree (agent_id);

create index organizations_addresses_waba_id_idx
on openbsp.organizations_addresses
using btree ((extra->>'waba_id'))
where service = 'whatsapp';

-- Index for efficient phone number lookups (used by MCP server)
create index organizations_addresses_phone_number_idx
on openbsp.organizations_addresses
using btree ((extra->>'phone_number'))
where service = 'whatsapp';


-- ------------------------------------------------------------
-- File: 03_models/03-02_contacts_addresses.sql
-- ------------------------------------------------------------

-- FRONTEND NOTE: PostgreSQL checks INSERT policy BEFORE conflict detection.
-- A member upsert whose payload carries synced.action='add' fails even if the
-- row exists — use .update() to touch a synced row.

create table openbsp.contacts_addresses (
  organization_id uuid not null,
  organization_address text not null,
  service openbsp.service not null,
  address text not null,
  extra jsonb,
  status text default 'active'::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

-- A row is an entry in ONE connection's address book, so the account key
-- (organization_id, service, organization_address) is part of the PK:
--
--   * service: the same canonical address (e.g. bare phone digits shared by
--     'whatsapp' and 'whatsapp-web') is a separate row per service.
--   * organization_address: opaque counterpart ids (BSUID, LID) are only
--     meaningful relative to the account that observed them, and each
--     connection syncs its own contact list — the same person reachable
--     through two of the org's numbers is a row per number. Visibility
--     follows the account too (a personal connection's contacts are the
--     owner's, see 05-02).
--
-- There is deliberately no cross-service/cross-account identity layer:
-- openbsp is a comm layer, and who-is-who across services belongs to the
-- consumer.
alter table only openbsp.contacts_addresses
add constraint contacts_addresses_pkey
primary key (organization_id, organization_address, service, address);

-- service is inside the reference so a contact row can never claim an account
-- of a different service, exactly as conversations does.
alter table only openbsp.contacts_addresses
add constraint contacts_addresses_organization_address_fkey
foreign key (organization_id, service, organization_address)
references openbsp.organizations_addresses(organization_id, service, address)
on delete cascade;

alter table only openbsp.contacts_addresses
add constraint contacts_addresses_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

create trigger set_extra
before update
on openbsp.contacts_addresses
for each row
when (
  new.extra is not null
)
execute function openbsp.merge_update('extra');

create trigger set_updated_at
before update
on openbsp.contacts_addresses
for each row
execute function openbsp.moddatetime('updated_at');

create trigger z_notify_webhook_contacts_addresses
after insert or update
on openbsp.contacts_addresses
for each row
execute function openbsp.notify_webhook();

-- A synced REMOVE means the entry left the service's address book: drop the
-- row too, unless conversation history still references the address — then it
-- stays (its extra keeps naming that history), flagged by synced.action.
create trigger cleanup_removed_address_if_empty
after update
on openbsp.contacts_addresses
for each row
when (
  new.extra->'synced'->>'action' = 'remove'
  and old.extra->'synced'->>'action' is distinct from 'remove'
)
execute function openbsp.cleanup_removed_address_if_empty();

-- Lookup by BSUID (e.g. the user_id_update handler matching extra.bsuid).
create index contacts_addresses_bsuid_idx
on openbsp.contacts_addresses
using btree ((extra->>'bsuid'))
where service = 'whatsapp';

-- Lookup by the replaced_by_bsuid trail when linking a new address back to the
-- old contact after a BSUID change.
create index contacts_addresses_replaced_by_bsuid_idx
on openbsp.contacts_addresses
using btree ((extra->>'replaced_by_bsuid'))
where service = 'whatsapp';


-- ------------------------------------------------------------
-- File: 03_models/03-03_conversations.sql
-- ------------------------------------------------------------

create table openbsp.conversations (
  organization_id uuid not null,
  id uuid default gen_random_uuid() not null,
  service openbsp.service not null,
  organization_address text not null,
  -- The peer this conversation is with — an individual or a group/channel
  -- address (e.g. WhatsApp phone/group JID, Slack channel id). Soft reference
  -- (no FK): peers span contacts and external containers.
  --
  -- Always present. For services with a real peer it is that peer's address.
  -- `local` has no external peer, so it addresses itself, in one of two ways
  -- (before_insert_on_conversations):
  --
  --   roster   a direct is DEFINED by who is in it — at any arity — so the
  --            address IS the participant list: agent ids, sorted, joined by
  --            ':'. Canonical, so the unique index below is what answers "does
  --            this conversation already exist between these people", for two
  --            participants and for eight alike.
  --   own id   group and channel have a name and a mutable membership, so
  --            their identity is their own, and the address is the row's id.
  --
  -- Keeping it NOT NULL is what lets the identity index below be a plain
  -- unique constraint instead of one whose behaviour depends on NULL
  -- semantics.
  address text not null,
  name text,
  -- The shape of the channel, in one cross-service vocabulary:
  --
  --   direct     member-defined  WhatsApp/Instagram DM, Slack im AND mpim
  --   group      private N       WhatsApp group, Slack/Teams private channel
  --   channel    public N        Slack public channel
  --   broadcast  fan-out         WhatsApp broadcast list
  --
  -- The cut is identity, not arity: a direct IS its member set — at any size
  -- (a Slack mpim is a multi-party direct) — so it can be neither joined nor
  -- left; adding a person names a different conversation. group and channel
  -- are named containers with a membership that changes. broadcast is not a
  -- conversation anyone is in — it fans out to N individual chats on the
  -- receiving side — and exists here because production already carries one
  -- (`…@broadcast`).
  --
  -- `text` + a check, deliberately not an enum: this column is referenced by
  -- an RLS policy, and `db diff` cannot add a value to an enum in that
  -- position (it attempts a recast and fails — see CLAUDE.md). More values
  -- are coming from whatsapp-web (newsletters/Channels), so the enum would
  -- cost a hand-written migration every time.
  --
  -- Set at creation and never changed afterwards, except on `local` where
  -- retyping a group as a channel is a real operation (Slack calls it
  -- "convert to public"). No API role can UPDATE a conversation on any other
  -- service (05-03), so a mirror row cannot be reclassified by a member.
  --
  -- Nullable, with no column default, so that "not classified yet" stays
  -- distinguishable from "classified as direct". Slack needs that: a reaction
  -- or a member_joined can create the row before anything knows the channel's
  -- kind, and ensureConversation re-resolves precisely while it is null. Every
  -- other path fills it — before_insert_on_conversations defaults it to
  -- `direct`, which is what a conversation minted from an incoming message is
  -- unless a connector said otherwise (generic-webhook states `group` for
  -- whatsapp-web group JIDs before the message lands).
  type text,
  -- Holds ingestor-owned facts (is_bot_member, is_multiple, channel_archived,
  -- topic, purpose) as well as cosmetic ones. Safe together because 05-03 grants no
  -- API role UPDATE on any service but `local`: the policy is what keeps
  -- members out, so nothing here needs a column of its own.
  extra jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.conversations
add constraint conversations_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

alter table only openbsp.conversations
add constraint conversations_pkey
primary key (id);

-- Not the identity — `id` alone is already unique — but the target a child
-- table needs to reference a conversation AND its tenant in one constraint,
-- so the two can never drift apart. See conversations_agents.
alter table only openbsp.conversations
add constraint conversations_organization_id_id_key
unique (organization_id, id);

alter table only openbsp.conversations
add constraint conversations_type_check
check (
  type is null
  or type in ('direct', 'group', 'channel', 'broadcast')
);

-- A conversation IS a channel: one row per peer on an account, for the life of
-- that peer. `id` is a convenience surrogate, not the identity.
--
-- This is what removes the lookup-then-insert race: every writer can upsert on
-- this key instead of select-then-maybe-insert.
--
-- Column ORDER is load-bearing, though uniqueness does not depend on it. With
-- organization_address second, the leading columns also serve:
--
--   (organization_id, organization_address, service)  the account FK below, so
--       deleting a connected account cascades by index scan (that cascade took
--       5.4 s against a sequential scan). Equality quals match the leading
--       columns in any order, so the FK's own column order need not agree.
--   (organization_id, organization_address)  "every conversation on this
--       account", the hottest lookup there is — 279k scans reading 539M tuples
--       through a single-column index, ~1.9k rows per probe on a shared number
--       carrying 13k conversations.
--   (organization_id)  the organization cascade.
--
-- Those three single-column indexes are therefore absent by design: this one
-- answers all of them, and each extra index is write cost on an insert path
-- that already runs a trigger cascade.
create unique index conversations_identity_idx
on openbsp.conversations
using btree (organization_id, organization_address, service, address);

-- Cascade (decided 2026-07-24): deleting a connected account deletes its
-- conversations, and messages cascade via conversations_id in turn.
--
-- service is in the reference so a conversation cannot name an account that
-- exists under a DIFFERENT service — the account rule in 04-02 reads visibility
-- off organizations_addresses.agent_id, so a mismatched anchor would decide who
-- sees the conversation.
alter table only openbsp.conversations
add constraint conversations_organization_address_fkey
foreign key (organization_id, service, organization_address)
references openbsp.organizations_addresses(organization_id, service, address)
on delete cascade;

create index conversations_updated_at_idx
on openbsp.conversations
using btree (updated_at);

create index conversations_address_idx
on openbsp.conversations
using btree (address);

create trigger handle_new_conversation
before insert
on openbsp.conversations
for each row
execute function openbsp.before_insert_on_conversations();

create trigger z_notify_webhook_conversations
after insert or update
on openbsp.conversations
for each row
execute function openbsp.notify_webhook();

create trigger preserve_addressing
before update
on openbsp.conversations
for each row
execute function openbsp.preserve_conversation_addressing();

create trigger set_extra
before update
on openbsp.conversations
for each row
when (
  new.extra is not null
)
execute function openbsp.merge_update('extra');

-- A `local` conversation is created by the member who starts it, through
-- PostgREST, so nothing else would record that they are in it — and under the
-- local rule (05-03) a non-`channel` conversation is visible to participants
-- only. Without this the creator would immediately lose sight of what they
-- just made. Service-role and API-key inserts have no auth.uid() and are
-- skipped.
create trigger add_local_participant
after insert
on openbsp.conversations
for each row
when (
  new.service = 'local'::openbsp.service
)
execute function openbsp.after_insert_on_local_conversation();

create trigger set_updated_at
before update
on openbsp.conversations
for each row
execute function openbsp.moddatetime('updated_at');


-- ------------------------------------------------------------
-- File: 03_models/03-04_agents.sql
-- ------------------------------------------------------------

create table openbsp.agents (
  organization_id uuid not null,
  user_id uuid,
  id uuid default gen_random_uuid() not null,
  name text not null,
  picture text,
  -- Access control, and only that. AI personas ("presupuestador
  -- metalúrgico", "Recopiladora de datos") are not roles; they stay in
  -- `extra`, where they belong next to the prompt.
  role openbsp.role default 'member'::openbsp.role not null,
  -- An agent with no `user_id` is nobody's membership — an AI agent: that is
  -- what agent-client runs, and what every access helper skips.
  --
  -- The one row shape that could lie is a person whose auth user was erased:
  -- user_id goes null, the agent survives, and it starts looking like an AI
  -- agent. Harmless in practice (agent-client needs a model and instructions
  -- to do anything), and the cure is upstream — an owner cannot erase their
  -- user at all (prevent_owner_user_deletion), and a member who leaves is
  -- marked deleted_at, which is the other half of the test.
  extra jsonb,
  -- Set by prevent_last_owner_deletion, which cancels the DELETE and marks the
  -- row instead: an agent outlives their membership, because messages name
  -- them as author and local rosters name them in the conversation ADDRESS
  -- itself. Every access helper (04-01, 04-02) skips a marked agent, so this
  -- revokes exactly what a delete would. Members cannot clear it —
  -- preserve_agent_deletion.
  deleted_at timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

-- TOTAL, not partial on deleted_at: one row per person per organization,
-- forever. A former member keeps their user_id, so re-adding them has to find
-- that row and revive it — which is what accept_invitation's ON CONFLICT does,
-- and it can only conflict against an index that still contains the marked
-- row. Minting a second agent instead would strand their message authorship
-- and every local DM keyed on the old id.
--
-- Nulls do not collide in Postgres, so AI agents (no user_id) are unaffected.
create unique index agents_organization_id_user_id_key
on openbsp.agents
using btree (organization_id, user_id);

-- Same purpose as the equivalent on conversations: a target for child tables
-- that must pin an agent AND its organization in one reference, so a row can
-- never name an agent from another tenant.
alter table only openbsp.agents
add constraint agents_organization_id_id_key
unique (organization_id, id);

alter table only openbsp.agents
add constraint agents_pkey
primary key (id);

alter table only openbsp.agents
add constraint agents_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

-- `set null`, not `cascade`: erasing the auth user must not erase the agent.
-- The person goes; the agent row stays, unclaimed, so message authorship and
-- the rosters that name them in a conversation address remain intact. A
-- cascade could not complete anyway, since deleting an agent row is cancelled
-- in favour of marking it.
alter table only openbsp.agents
add constraint agents_user_id_fkey
foreign key (user_id)
references auth.users(id)
on delete set null;

-- Declared here (not in 03-01) because agents is created after
-- organizations_addresses. `restrict`: deleting a connected account is an
-- API-side operation (revoke tokens etc.), not just a row delete — so an
-- agent cannot be removed while it still owns addresses. Offboarding deletes
-- the address first (cascading its data: if the account's owner goes away,
-- its messages do too), then the agent.
alter table only openbsp.organizations_addresses
add constraint organizations_addresses_agent_id_fkey
foreign key (agent_id)
references openbsp.agents(id)
on delete restrict;

create index agents_user_id_idx
on openbsp.agents
using btree (user_id);

-- `z_` so it sorts after prevent_last_owner_deletion_before_delete: the guard
-- must get its chance to raise before the delete turns into a mark.
create trigger z_mark_deleted
before delete
on openbsp.agents
for each row
execute function openbsp.mark_agent_deleted();

create trigger preserve_deletion
before update
on openbsp.agents
for each row
execute function openbsp.preserve_agent_deletion();

create trigger set_extra
before update
on openbsp.agents
for each row
when (
  new.extra is not null
)
execute function openbsp.merge_update('extra');

create trigger set_updated_at
before update
on openbsp.agents
for each row
execute function openbsp.moddatetime('updated_at');

-- `user_id is not null`: an owner is a person, and having an auth identity
-- is what makes one — it holds even for an AI agent that somehow carries the
-- owner role.
--
-- `old.deleted_at is null` on the update guard: a marked agent is already not
-- an owner as far as every access helper is concerned, so reviving one at a
-- lower role is not a demotion the last-owner rule has any business refusing.
create trigger prevent_last_owner_deletion_before_update
before update
on openbsp.agents
for each row
when (
  old.user_id is not null
  and old.deleted_at is null
  and old.role = 'owner'
  and new.role <> 'owner'
)
execute function openbsp.prevent_last_owner_deletion();

create trigger prevent_last_owner_deletion_before_delete
before delete
on openbsp.agents
for each row
when (
  old.user_id is not null
  and old.role = 'owner'
)
execute function openbsp.prevent_last_owner_deletion();


-- ------------------------------------------------------------
-- File: 03_models/03-05_messages.sql
-- ------------------------------------------------------------

-- organization_id is useful for realtime.
create table openbsp.messages (
  organization_id uuid not null,
  conversation_id uuid not null,
  id uuid default gen_random_uuid() not null,
  external_id text,
  agent_id uuid, -- internal sender (should be not null for internal and outgoing)
  -- denormalized properties
  service openbsp.service not null,
  organization_address text not null,
  -- Unified peer addressing:
  -- conversation_address — the peer the conversation is with (individual or
  --   group/channel). Soft reference, like content.re_message_id.
  -- sender_address — the CONTACT who authored the message (a WhatsApp
  --   phone/BSUID, a Slack workspace member — ties to contacts_addresses,
  --   soft reference), or null when the account itself spoke (UI/AI sends,
  --   echoes, history, tool traces). Deliverability is NOT an authorship
  --   question: the dispatch trigger arms on status.pending plus not being
  --   record-only (content.internal). Fill-once: a Slack echo fills null
  --   with the member who actually sent; a non-null sender is immutable.
  conversation_address text,
  sender_address text,
  ----
  content jsonb not null,
  status jsonb default jsonb_build_object('pending', now()) not null,
  timestamp timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.messages
add constraint messages_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

alter table only openbsp.messages
add constraint messages_conversation_id_fkey
foreign key (conversation_id)
references openbsp.conversations(id)
on delete cascade;

alter table only openbsp.messages
add constraint messages_agent_id_fkey
foreign key (agent_id)
references openbsp.agents(id)
on delete set null;

alter table only openbsp.messages
add constraint messages_pkey primary key (id);

alter table only openbsp.messages
add constraint messages_external_id_key unique (external_id);

-- Declared NOT VALID (not inline) to match the deployed state. ~46k legacy
-- messages predate the v1 content schema (no version/kind) and were never
-- checked, so the constraint cannot be validated; it still enforces the shape
-- for every new row. Declaring NOT VALID here keeps `supabase db diff` from
-- re-emitting a drop/re-add on every run. See migration
-- 20260424132025_fix_messages_content_schema_allow_empty.
alter table only openbsp.messages
add constraint messages_content_schema check (
  content = '{}'::jsonb -- status-only upserts (content merged later)
  or (
    content->>'version' is not null
    and content->>'type' in ('text', 'file', 'data')
    and content->>'kind' is not null
  )
) not valid;

-- No plain (organization_id) index: messages_org_conv_timestamp_idx below
-- leads with that column, so it serves the organization cascade too.

-- Needed on its own even though the composite below mentions the column: that
-- one leads with organization_id, so it cannot answer a conversation-only
-- probe — which is what the cascade from conversations runs.
create index messages_conversation_id_idx
on openbsp.messages
using btree (conversation_id);

-- Serves the two per-minute sweeps (dispatch-outgoing-pending-messages,
-- preprocess-pending-messages), which scan a rolling 12-hour window by
-- timestamp. 728k scans, and the reason this index is not merely the
-- less-used sibling of created_at below.
create index messages_timestamp_idx
on openbsp.messages
using btree (timestamp);

-- Incremental polling by API clients: `where service = ? and created_at >= ?
-- order by created_at desc`. Unindexed, that was the single most expensive
-- statement in production — 10,608 calls, 174 ms mean, ~86 GB read from disk —
-- because nothing indexed created_at at all and every call sorted the table.
create index messages_service_created_at_idx
on openbsp.messages
using btree (service, created_at desc);

create index messages_updated_at_idx
on openbsp.messages
using btree (updated_at);

create index messages_org_conv_timestamp_idx
on openbsp.messages
using btree (organization_id, conversation_id, timestamp desc);

-- Media-object → referencing-message lookup (is_media_visible, used by the
-- storage.objects download policy). v1 file parts only: v0 legacy media is
-- not matched, so it stays org-scoped like any unreferenced object.
create index messages_file_uri_idx
on openbsp.messages
using btree ((content->'file'->>'uri'))
where content->'file'->>'uri' is not null;

create trigger handle_new_message
before insert
on openbsp.messages
for each row
execute function openbsp.before_insert_on_messages();

-- Team chat is excluded here rather than left to agent-client, which refuses
-- it anyway: a mirrored workspace can be thousands of messages a day, and
-- every one of them would spend an invocation to be told no. `local` cannot
-- arm this trigger at all (a colleague is not a contact, so sender_address is
-- null), but it is named for the same reason discord and teams are not —
-- saying what the rule is beats relying on why it cannot happen.
create trigger handle_incoming_message_to_agent
after insert
on openbsp.messages
for each row
when (
  new.sender_address is not null
  and new.service not in ('local'::openbsp.service, 'slack'::openbsp.service)
  and (new.status ->> 'pending') is not null
)
execute function openbsp.edge_function('/agent-client', 'post');

-- The internal mirror of the trigger above: `agent_id` is authorship in
-- member space the way `sender_address` is in contact space. Only `local`
-- and only armed rows; whether the room actually IS an AI DM is the
-- function's question — a WHEN clause cannot look inside the address. The
-- internal clause mirrors the dispatch trigger's: writers insert record-only
-- rows unarmed, but an AI waking up to a tool trace should not depend on
-- writer discipline either.
create trigger handle_local_message_to_agent
after insert
on openbsp.messages
for each row
when (
  new.agent_id is not null
  and new.service = 'local'::openbsp.service
  and (new.status ->> 'pending') is not null
  and new.content ->> 'internal' is null
)
execute function openbsp.local_message_to_agent();

-- Team chat is excluded, and `local` was never the whole of it: reading a
-- colleague's message is not a receipt owed to anyone outside, and on Slack
-- there is no user-token API to deliver one with. It also matters now that
-- Slack rows carry status.pending like every other inbound message — without
-- this, every read would POST to slack-dispatcher for nothing.
--
-- Internal comms have a second, unanswered question anyway: a read is by ONE
-- of several members, so "the message was read" is not a fact about the
-- conversation. See TODO.
create trigger handle_mark_as_read_to_dispatcher
after update
on openbsp.messages
for each row
when (
  new.sender_address is not null
  and new.service not in ('local'::openbsp.service, 'slack'::openbsp.service)
  and (
    (old.status ->> 'read') <> (new.status ->> 'read')
    or (old.status ->> 'typing') <> (new.status ->> 'typing')
  )
  and (new.status ->> 'pending') is not null
)
execute function openbsp.dispatcher_edge_function();

-- Sendability is three facts: the account authored the row (sender null),
-- it is armed (pending — scheduled sends wait for their timestamp), and it
-- is not record-only (content.internal, the writer-declared marker on tool
-- traces, agent errors, internal notes). There is deliberately no kind
-- filter: a kind no service can encode should not be inserted armed, and a
-- writer that does gets a loud `failed` stamp from the dispatcher instead
-- of a silent no-op here.
create trigger handle_outgoing_message_to_dispatcher
after insert
on openbsp.messages
for each row
when (
  new.sender_address is null
  and new.timestamp <= now()
  and (new.status ->> 'pending') is not null
  and new.content ->> 'internal' is null
)
execute function openbsp.dispatcher_edge_function();

-- The rows the dispatch trigger above sends, scheduled ones included. Named
-- to sort after handle_new_message: BEFORE triggers fire alphabetically, and
-- that one fills in the service.
create trigger limit_text_length
before insert
on openbsp.messages
for each row
when (
  new.sender_address is null
  and (new.status ->> 'pending') is not null
  and new.content ->> 'internal' is null
  and new.content ->> 'text' is not null
)
execute function openbsp.limit_text_length();

create trigger handle_message_to_media_preprocessor
after insert
on openbsp.messages
for each row
when (
  (new.status ->> 'pending') is not null
  and (new.content ->> 'type') = 'file'
)
execute function openbsp.edge_function('/media-preprocessor', 'post');

create trigger z_notify_webhook_messages
after insert or update
on openbsp.messages
for each row
execute function openbsp.notify_webhook();

-- Named to sort before set_message: BEFORE triggers fire alphabetically, and
-- this one decides what the merge receives.
create trigger keep_stored_media
before update
on openbsp.messages
for each row
when (
  new.content ->> 'kind' = 'media_placeholder'
  or new.content ->> 'type' = 'file'
)
execute function openbsp.keep_stored_media();

-- Addressing is set (and validated against the conversation) at insert and
-- frozen here; updates only fill sender_address once and merge content/status.
create trigger preserve_addressing
before update
on openbsp.messages
for each row
execute function openbsp.preserve_message_addressing();

create trigger set_message
before update
on openbsp.messages
for each row
when (
  new.content is not null
)
execute function openbsp.merge_update('content');

create trigger set_status
before update
on openbsp.messages
for each row
when (
  new.status is not null
)
execute function openbsp.merge_update('status');

create trigger set_updated_at
before update
on openbsp.messages
for each row
execute function openbsp.moddatetime('updated_at');


-- ------------------------------------------------------------
-- File: 03_models/03-06_api_keys.sql
-- ------------------------------------------------------------

create table openbsp.api_keys (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  role openbsp.role default 'member'::openbsp.role not null,
  name text not null,
  key text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.api_keys
add constraint api_keys_key_key
unique (key);

alter table only openbsp.api_keys
add constraint api_keys_pkey
primary key (id);

alter table only openbsp.api_keys
add constraint api_keys_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

create index api_keys_organization_idx
on openbsp.api_keys
using btree (organization_id);

create trigger set_updated_at
before update
on openbsp.api_keys
for each row
execute function openbsp.moddatetime('updated_at'); 

-- ------------------------------------------------------------
-- File: 03_models/03-07_webhooks.sql
-- ------------------------------------------------------------

create table openbsp.webhooks (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  table_name openbsp.webhook_table not null,
  operations openbsp.webhook_operation[] not null,
  url character varying not null,
  token character varying,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.webhooks
add constraint webhooks_pkey
primary key (id);

alter table only openbsp.webhooks
add constraint webhooks_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

create index webhooks_organization_idx
on openbsp.webhooks
using btree (organization_id);

create trigger set_updated_at
before update
on openbsp.webhooks
for each row
execute function openbsp.moddatetime('updated_at'); 

-- ------------------------------------------------------------
-- File: 03_models/03-10_logs.sql
-- ------------------------------------------------------------

create type openbsp.log_level as enum ('info', 'warning', 'error');

create table openbsp.logs (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null references openbsp.organizations(id) on delete cascade,
  organization_address text,
  level openbsp.log_level not null,
  category text not null,
  service openbsp.service,
  message text not null,
  metadata jsonb,
  created_at timestamp with time zone not null default now()
);

alter table only openbsp.logs
add constraint logs_pkey
primary key (id);

-- Both columns are nullable (an org-level log names no account), and under
-- MATCH SIMPLE a null in either one skips the check entirely. The constraint
-- below is what keeps that from becoming a hole: state a service whenever you
-- state an address, so an addressed log is always checked.
alter table only openbsp.logs
add constraint logs_organization_address_needs_service
check (organization_address is null or service is not null);

alter table only openbsp.logs
add constraint logs_organization_address_fkey
foreign key (organization_id, service, organization_address)
references openbsp.organizations_addresses(organization_id, service, address)
on delete cascade;

-- service last, so the leading pair still answers "logs for this account"
-- while all three columns are present for the account cascade above.
create index idx_logs_organization_id_address
on openbsp.logs
using btree (organization_id, organization_address, service);

create index idx_logs_created_at
on openbsp.logs
using btree (created_at desc);

create trigger z_notify_webhook_logs
after insert
on openbsp.logs
for each row
execute function openbsp.notify_webhook();

-- ------------------------------------------------------------
-- File: 03_models/03-11_onboarding_tokens.sql
-- ------------------------------------------------------------

create table openbsp.onboarding_tokens (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  organization_id uuid not null,
  created_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone not null,
  used_at timestamp with time zone,
  status text default 'active'::text not null,
  service openbsp.service not null,
  -- Optional per-account webhook override (tech provider as a service): when set, the connected
  -- WABA's message webhooks are pointed at callback_url (verified by
  -- verify_token) so the org's own app receives traffic directly.
  callback_url text,
  verify_token text,
  constraint onboarding_tokens_status_check check (status in ('active', 'used', 'expired'))
);

alter table only openbsp.onboarding_tokens
add constraint onboarding_tokens_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;


-- ------------------------------------------------------------
-- File: 03_models/03-13_conversations_agents.sql
-- ------------------------------------------------------------

-- Who is in a conversation. Two sources, by service:
--
--   mirror services  Membership of the container on the external service
--                    (Slack channel members) intersected with org members who
--                    connected it. Maintained by the service's webhook and
--                    management functions with the service role.
--
--   local            OpenBSP's own chat, where membership is the product:
--                    the creator is recorded by a trigger, and members add,
--                    join and leave through RLS (05-12).
--
-- Where a conversation is visible org-wide anyway (a shared inbox), a row
-- here is not what grants that — it just carries the member's own state for
-- the conversation in `extra`. Either way the split above is the one 05-12
-- enforces: members write this table on `local`, and read it everywhere.
create table openbsp.conversations_agents (
  organization_id uuid not null,
  -- The account this row stems from: on a mirror service the member's personal
  -- one (their Slack identity T…:U…), NOT the shared anchor the conversation
  -- hangs off; on `local`, the org's single local address, which is the only
  -- one there is. Cascade makes "disconnect = delete the address row" drop
  -- this connection's visibility, and nothing from other services.
  --
  -- Always the conversation's own — a Slack membership stems from a Slack
  -- identity — so it is redundant in principle and required in practice:
  -- organizations_addresses is keyed on it, and the reference below cannot pin
  -- the account without it. Writer-stated, like every other column: a wrong
  -- value fails the account FK, because the services that populate this table
  -- give their addresses disjoint formats (`local` addresses are org uuids,
  -- Slack's are `T…:U…`), so no address string exists under more than one.
  service openbsp.service not null,
  organization_address text not null,
  conversation_id uuid not null,
  agent_id uuid not null,
  -- Per-member state about the conversation: muted, last_read_ts. Members
  -- write it on `local` (05-12); on a mirror service the row is the sync's,
  -- and so is this. NOT UI preferences (archived, pinned, drafts), which have
  -- to be settable on any conversation you can see.
  extra jsonb,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.conversations_agents
add constraint conversations_agents_pkey
primary key (conversation_id, agent_id);

alter table only openbsp.conversations_agents
add constraint conversations_agents_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

alter table only openbsp.conversations_agents
add constraint conversations_agents_organization_address_fkey
foreign key (organization_id, service, organization_address)
references openbsp.organizations_addresses(organization_id, service, address)
on delete cascade;

-- Both references carry organization_id, so the tenant cannot disagree with
-- itself. Members write this table (05-12), and organization_id is theirs to
-- state; single-column references would leave it free to name ANOTHER
-- organization while conversation_id names ours — the pair FK above only
-- checks its two columns against each other — and would let a local group
-- accept an agent from another organization. Cross-tenant writes, and the
-- first would invert the cascade: a stranger's address row could then delete
-- our membership.
alter table only openbsp.conversations_agents
add constraint conversations_agents_conversation_id_fkey
foreign key (organization_id, conversation_id)
references openbsp.conversations(organization_id, id)
on delete cascade;

alter table only openbsp.conversations_agents
add constraint conversations_agents_agent_id_fkey
foreign key (organization_id, agent_id)
references openbsp.agents(organization_id, id)
on delete cascade;

-- Default privileges for postgres-created tables only grant
-- truncate/references/trigger to the API roles, so new tables need explicit
-- grants. service_role writes memberships (webhook/management functions);
-- members only read (RLS narrows rows to their own).
grant select, insert, update, delete on table openbsp.conversations_agents to service_role;
-- Writes are granted at table level and narrowed by 05-12; anon (the API-key
-- path) gets nothing here, since every write policy means "my own row" or
-- "a local room I am in", and an API key is nobody.
grant select, insert, update, delete on table openbsp.conversations_agents to authenticated;

create index conversations_agents_agent_id_idx
on openbsp.conversations_agents
using btree (agent_id);

create index conversations_agents_organization_id_idx
on openbsp.conversations_agents
using btree (organization_id);

-- Supports the on-delete-cascade lookup from organizations_addresses.
create index conversations_agents_organization_address_idx
on openbsp.conversations_agents
using btree (organization_id, service, organization_address);

create trigger set_extra
before update
on openbsp.conversations_agents
for each row
when (
  new.extra is not null
)
execute function openbsp.merge_update('extra');

create trigger set_updated_at
before update
on openbsp.conversations_agents
for each row
execute function openbsp.moddatetime('updated_at');


-- ------------------------------------------------------------
-- File: 03_models/03-14_invitations.sql
-- ------------------------------------------------------------

-- An invitation is a pending offer of membership, not a member: an agents
-- row means a member, unconditionally. Keeping the pending state in its own
-- table means no access helper needs an exclusion clause it could forget —
-- and forgetting one anywhere would grant access to someone who never
-- replied.
--
-- EMAIL is the key. The invitee typically has no auth user yet, and when they
-- do they are not in the organization, so nothing about them can be named by
-- id at invitation time. Their identity is resolved once, at acceptance, from
-- the JWT.
create table openbsp.invitations (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  email text not null,
  -- The role the agent gets on acceptance. Stated by the inviter, applied by
  -- accept_invitation, and never by the invitee: this is the only path by
  -- which someone new arrives with a role, so it is the only place the role
  -- can be chosen for them.
  role openbsp.role default 'member'::openbsp.role not null,
  -- text with a check rather than an enum, for the reason documented on
  -- conversations.type: RLS references this column, and `db diff` cannot add a
  -- value to an enum a policy depends on.
  status text default 'pending' not null,
  invited_by uuid,
  -- What the offer says, for the one reader who cannot look any of it up: the
  -- invitee sees this table and nothing else. Nullable because the writer
  -- omits them — before_insert_or_update_on_invitations fills all three, and
  -- leaves the last two null when there is nobody to copy (invited_by null,
  -- or an agent from another organization). Note the email is the inviter's,
  -- and so is visible to every member through the policy below, which is the
  -- only place an agent's address is readable at all.
  organization_name text,
  invited_by_name text,
  invited_by_email text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table only openbsp.invitations
add constraint invitations_pkey
primary key (id);

alter table only openbsp.invitations
add constraint invitations_status_check
check (status in ('pending', 'accepted', 'rejected', 'revoked'));

alter table only openbsp.invitations
add constraint invitations_organization_id_fkey
foreign key (organization_id)
references openbsp.organizations(id)
on delete cascade;

-- Provenance only. Agents are marked deleted rather than removed, so this
-- nulls in practice only when the organization is being dropped anyway.
alter table only openbsp.invitations
add constraint invitations_invited_by_fkey
foreign key (invited_by)
references openbsp.agents(id)
on delete set null;

-- One open offer per address per organization — the constraint the old
-- implementation faked with a trigger that ran a lookup and raised. Partial,
-- so a rejected or revoked invitation does not block a later one; lowered,
-- because auth.users normalises email and an invitation typed in mixed case
-- must still collide with it.
create unique index invitations_pending_email_key
on openbsp.invitations
using btree (organization_id, lower(email))
where status = 'pending';

-- "My pending invitations", the signed-in user's cross-organization lookup
-- behind the banner on the conversations page. No organization to scope it by
-- — that is the point of an invitation — so email is all there is to index.
create index invitations_email_idx
on openbsp.invitations
using btree (lower(email))
where status = 'pending';

create trigger handle_invitation_snapshot
before insert or update
on openbsp.invitations
for each row
execute function openbsp.before_insert_or_update_on_invitations();

create trigger set_updated_at
before update
on openbsp.invitations
for each row
execute function openbsp.moddatetime('updated_at');

-- The invitee hears about an offer when it is made, and the inviter when it
-- is taken. Rejections and revocations stay quiet.
create trigger notify_invitation_received
after insert
on openbsp.invitations
for each row
when (new.status = 'pending')
execute function openbsp.edge_function('/notifications', 'post');

create trigger notify_invitation_accepted
after update of status
on openbsp.invitations
for each row
when (old.status = 'pending' and new.status = 'accepted')
execute function openbsp.edge_function('/notifications', 'post');

-- Default privileges for postgres-created tables only grant the owner, so the
-- API roles need these explicitly. Rows are narrowed by 05-13; anon is here
-- because an owner-scoped API key may run the invitation flow, exactly as it
-- may on agents.
grant select, insert, update, delete on table openbsp.invitations to service_role;
grant select, insert, update, delete on table openbsp.invitations to authenticated, anon;


-- ------------------------------------------------------------
-- File: 03_models/03-12_auth.users.sql
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS prevent_owner_user_deletion ON auth.users;
create trigger prevent_owner_user_deletion
before delete
on auth.users
for each row
execute function openbsp.prevent_owner_user_deletion();


-- ------------------------------------------------------------
-- File: 04_functions_post_tables/04-01_auth_helpers.sql
-- ------------------------------------------------------------

create or replace function openbsp.get_authorized_orgs(role openbsp.role default 'member') returns setof uuid
language plpgsql
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  req_level int;
  api_key text;
  org_id uuid;
begin
  req_level := case role::text
    when 'owner' then 3
    when 'admin' then 2
    else 1 -- 'member'
  end;

  -- First, try JWT authentication via auth.uid()
  if auth.uid() is not null then
    -- Aliased because the parameter is also called `role`: a bare `role` here
    -- would resolve to it, and every caller would come back an owner.
    --
    -- No invitation clause: an agents row is a member, full stop. It used to
    -- also have to exclude rows whose invitation was still pending, and every
    -- helper that forgot to was a hole. Invitations are their own table now.
    return query select a.organization_id from openbsp.agents a
    where
      a.user_id = auth.uid()
    -- A deleted agent is a former member: this is what makes marking the row
    -- revoke access rather than merely rename it.
    and a.deleted_at is null
    and (
      case a.role
        when 'owner' then 3
        when 'admin' then 2
        else 1 -- 'member'
      end
    ) >= req_level;

    -- Authenticated but lacking the requested role: return the empty set so RLS
    -- subqueries can fall through to other OR-combined policies (e.g. a member
    -- editing themselves while an owner-only policy is also evaluated).
    -- Raising here would short-circuit the whole RLS evaluation.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('insufficient permissions, %s role required', role::text);
    return;
  end if;

  -- Fallback to API key authentication
  api_key := current_setting('request.headers', true)::json->>'api-key';

  if api_key is not null then
    select a.organization_id into org_id
    from openbsp.api_keys a
    where a.key = api_key
    and (
      case (a.role::text)
        when 'owner' then 3
        when 'admin' then 2
        else 1 -- 'member'
      end
    ) >= req_level;

    if org_id is not null then
      return next org_id;
    end if;
    -- Same reasoning as the JWT branch: invalid key or insufficient role returns
    -- the empty set, not a raise. Validate api-key existence at the request edge
    -- (e.g. a pre-request hook) if you want loud failure for missing/invalid keys.
    -- raise exception using
    --   errcode = '42501',
    --   message = format('invalid api key or insufficient permissions, %s role required', role::text);
    return;
  end if;

  raise exception using
    errcode = '42501',
    message = 'authentication required',
    hint = 'use api-key header or jwt authentication';
end;
$$;

-- WITH CHECK sees the proposed row and nothing else, so "this column may not
-- change" cannot be written as a policy expression — it needs the stored row
-- to compare against. That is all these two do: re-read the row by id under
-- SECURITY DEFINER (also avoiding RLS recursion on agents) and confirm the
-- columns the caller is not allowed to move still hold their old values.
--
-- Identity: which organization the row belongs to, and which person it names.
-- Neither is editable by anyone through the API — an agent that could change
-- organization_id would be a tenant escape, and one that could change user_id
-- would be an impersonation. (`user_id` doubles as the AI test, so pinning
-- it also pins that.)
create or replace function openbsp.agent_identity_unchanged(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to openbsp, auth, extensions, pg_catalog
as $$
begin
  return exists (
    select 1 from openbsp.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
  );
end;
$$;

-- Identity plus role, for the two callers who may edit an agent but not
-- promote anyone: a member editing themselves, and an admin editing a
-- colleague. Granting a role is an owner's privilege, so owners get the
-- function above instead.
create or replace function openbsp.agent_identity_and_role_unchanged(
  p_id uuid,
  p_user_id uuid,
  p_organization_id uuid,
  p_role openbsp.role
) returns boolean
language plpgsql
security definer -- avoid RLS infinite recursion
set search_path to openbsp, auth, extensions, pg_catalog
as $$
begin
  return exists (
    select 1 from openbsp.agents
    where id = p_id
      and user_id is not distinct from p_user_id
      and organization_id = p_organization_id
      and role = p_role
  );
end;
$$;

-- The caller's own agent rows, across every org they belong to. A user has at
-- most one agent per organization (agents_organization_id_user_id_key), so
-- this is "which agent am I here". Set-returning for the same reason as the
-- visibility helpers: `agent_id in (select …)` is an InitPlan evaluated once.
--
-- Empty for API keys — they authenticate without auth.uid() and are nobody in
-- particular, so no policy branch that means "my own row" can ever match one.
create or replace function openbsp.get_own_agents() returns setof uuid
language sql
stable
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  select a.id from openbsp.agents a
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;


-- ------------------------------------------------------------
-- File: 04_functions_post_tables/04-02_visibility_helpers.sql
-- ------------------------------------------------------------

-- Who sees a conversation: the ACCOUNT rule decides by default, and a
-- conversation may override it.
--
--   Account (organizations_addresses.agent_id):
--     null => public — a shared inbox, visible to the whole org
--     set  => private — a personal account, visible to its owner
--
--   Restriction (get_restricted_conversations below):
--     the account rule is suppressed for conversations two services host on
--     an ownerless account without meaning "shared with the whole org".
--     Those are visible to conversations_agents participants only.
--
-- The restriction exists because one ownerless account can host both modes:
--
--   slack  The workspace anchor is ownerless and holds the bot — the
--          shared-inbox connection, exactly like a common WhatsApp number —
--          while each member's T…:U… row is personal. Every conversation
--          hangs off the anchor regardless of which connection it arrived
--          through, so "is this shared?" is a fact about the conversation.
--          The bot's presence IS that fact, and is what the webhook actually
--          observes (member_joined/left_channel), so it is what we store.
--          Absent means absent: a conversation the bot is not in is not
--          shared, which is the fail-closed direction.
--
--   local  One ownerless account per org hosts the whole internal chat, so
--          the account says nothing. Shape decides instead, exactly as it
--          would in Slack or Teams: `channel` is open to the org, everything
--          else (direct, group) is for its participants.
--
-- Both services are named explicitly, rather than reading a flag every
-- ingestor would have to remember to write — an absent flag fails open, and
-- this must fail closed. A new service that needs a restriction adds a line
-- here; one that does not, adds nothing.
--
-- There is deliberately NO role bypass: owners/admins cannot read a member's
-- personal conversations. API keys authenticate without auth.uid(), so they
-- only ever see shared-inbox content.
--
-- SHAPE: these return SETS and take no per-row arguments, so the policies can
-- call them as `x in (select …)` — an InitPlan evaluated once per query and
-- then hash-probed per row, the same trick that makes get_authorized_orgs
-- cheap. A boolean helper taking the row's columns cannot get that treatment:
-- it is re-invoked per row, and being SECURITY DEFINER it cannot be inlined
-- either.

-- Accounts whose conversations the caller can see, as (organization_id,
-- service, address) triples: the org's shared inboxes, plus personal accounts
-- the caller owns. Conversations under these are visible unless their override
-- says private.
--
-- service is in the tuple because it is in the account key: the same address
-- string can name a shared 'whatsapp' account and a personal 'whatsapp-web'
-- one, and matching on the pair alone would let either decide for both.
create or replace function openbsp.get_visible_addresses()
returns table (organization_id uuid, service openbsp.service, address text)
language sql
stable
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  -- Shared inboxes: any ownerless account in an org the caller belongs to. No
  -- auth.uid() in the ownerless test itself, so this is the only rule an API
  -- key can satisfy.
  --
  -- The org filter is redundant with every policy that calls this — each one
  -- already ANDs `organization_id in get_authorized_orgs(…)`. It is here
  -- because policies are not the only caller: this is a public, SECURITY
  -- DEFINER function, so PostgREST publishes it at /rpc/get_visible_addresses,
  -- where nothing wraps it and RLS does not apply. Without the filter that
  -- call answers with every shared inbox in the DATABASE — other tenants' org
  -- ids and account addresses, WhatsApp business numbers among them.
  select oa.organization_id, oa.service, oa.address
  from openbsp.organizations_addresses oa
  where oa.agent_id is null
    and oa.organization_id in (select openbsp.get_authorized_orgs('member'))
  union
  -- Personal accounts owned by the caller (their Slack identity, a personal
  -- WhatsApp/mailbox).
  select oa.organization_id, oa.service, oa.address
  from openbsp.organizations_addresses oa
  join openbsp.agents a on a.id = oa.agent_id
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;

-- Conversations the caller participates in: a conversations_agents row names
-- an agent that is the caller. Mirrors channel/DM membership on the external
-- service, and is the only way into a restricted conversation.
create or replace function openbsp.get_participant_conversations()
returns setof uuid
language sql
stable
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  select ca.conversation_id
  from openbsp.conversations_agents ca
  join openbsp.agents a on a.id = ca.agent_id
  where a.user_id = auth.uid() and a.deleted_at is null;
$$;

-- Conversations whose account rule is suppressed — see the two cases at the
-- top of this file. Scoped to the caller's orgs so the set stays bounded.
--
-- Members can influence neither branch. `extra` is writable in principle, but
-- 05-03 grants UPDATE on conversations to no API role except on `local`, so
-- nobody can claim the bot is in a channel it is not in; and `type` is
-- restored from the old row on every API-role update
-- (preserve_conversation_addressing), so a participant cannot retype a private
-- room as a channel and publish it to the organization.
create or replace function openbsp.get_restricted_conversations()
returns setof uuid
language sql
stable
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  select c.id
  from openbsp.conversations c
  where c.organization_id in (select openbsp.get_authorized_orgs('member'))
    and (
      -- Slack: shared iff the bot is in it.
      (
        c.service = 'slack'::openbsp.service
        and not coalesce((c.extra->>'is_bot_member')::boolean, false)
      )
      -- local: shared iff it is a public channel.
      or (
        c.service = 'local'::openbsp.service
        and c.type is distinct from 'channel'
      )
    );
$$;

-- Boolean form, for callers that hold a single row rather than a query to
-- filter (is_media_visible). Same rules, expressed through the same two
-- functions so the two forms cannot drift apart. Do NOT use this in a policy
-- over a large table: per-row arguments defeat the InitPlan.
create or replace function openbsp.is_conversation_visible(
  conv_id uuid,
  conv_org uuid,
  conv_addr text,
  conv_service openbsp.service
) returns boolean
language sql
stable
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  select
    (
      (conv_org, conv_service, conv_addr) in (
        select v.organization_id, v.service, v.address
        from openbsp.get_visible_addresses() v
      )
      and conv_id not in (select openbsp.get_restricted_conversations())
    )
    or conv_id in (select openbsp.get_participant_conversations());
$$;

-- Whether the caller may download a media object (storage path
-- organizations/<org>/attachments/<file>). Rule: an object nobody references
-- stays org-scoped (covers freshly uploaded files whose message doesn't
-- exist yet, and v0-content legacy media, which only v1 file parts can
-- reference here); a referenced object requires at least one referencing
-- message whose conversation the caller can see. SECURITY DEFINER on
-- purpose: with invoker rights the invisible referencing messages would be
-- hidden by RLS and the check could not distinguish "unreferenced" from
-- "referenced but private".
create or replace function openbsp.is_media_visible(object_name text) returns boolean
language sql
stable
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
  with refs as (
    select m.conversation_id, m.organization_id, m.service, m.organization_address
    from openbsp.messages m
    where m.content->'file'->>'uri' = 'internal://media/' || object_name
  )
  select
    not exists (select 1 from refs)
    or exists (
      select 1 from refs r
      where openbsp.is_conversation_visible(
        r.conversation_id, r.organization_id, r.organization_address, r.service
      )
    );
$$;


-- ------------------------------------------------------------
-- File: 04_functions_post_tables/04-03_invitations.sql
-- ------------------------------------------------------------

-- Answering an invitation is the one operation that crosses the membership
-- boundary: the caller is not in the organization, and the row it has to write
-- is an agents row there. No policy can express that without also opening
-- agents to strangers, so it lives in a function instead — the invitee holds
-- SELECT on invitations and nothing else (05-13), and these two are the only
-- doors.

-- Returns the agent id the caller now holds in the organization.
create or replace function openbsp.accept_invitation(invitation_id uuid) returns uuid
language plpgsql
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  claims jsonb := auth.jwt();
  caller uuid := auth.uid();
  caller_email text := claims->>'email';
  inv openbsp.invitations;
  agent_id uuid;
begin
  if caller is null or caller_email is null then
    raise exception 'authentication required'
      using errcode = '42501';
  end if;

  -- `for update` so two clicks on the same link cannot both pass the pending
  -- test and race to insert.
  select * into inv
  from openbsp.invitations
  where id = invitation_id
    and status = 'pending'
    and lower(email) = lower(caller_email)
  for update;

  if not found then
    raise exception 'no pending invitation for this account'
      using errcode = '42501';
  end if;

  -- Revive a former member rather than mint a second agent: the agent id is
  -- named by message authorship and by the ADDRESS of every local direct
  -- they were in, so a new id would strand both — the old DM would
  -- have no live participant and a new one would appear beside it. This is
  -- also why the unique index on (organization_id, user_id) is total rather
  -- than partial on deleted_at: it has to see the marked row to conflict with
  -- it.
  --
  -- SECURITY DEFINER carries this past preserve_agent_deletion, which pins
  -- deleted_at for every role but the owner's — clearing it is exactly the
  -- privilege being exercised here, and only here.
  insert into openbsp.agents (organization_id, user_id, name, role)
  values (
    inv.organization_id,
    caller,
    coalesce(claims->'user_metadata'->>'full_name', caller_email),
    inv.role
  )
  on conflict (organization_id, user_id) do update
    set deleted_at = null,
        -- The invitation decides the role of someone coming back, so a
        -- re-added owner does not silently return as one. An agent who never
        -- left keeps theirs: an invitation must not be a side channel for
        -- demoting a sitting member.
        role = case
          when openbsp.agents.deleted_at is not null then excluded.role
          else openbsp.agents.role
        end
  returning id into agent_id;

  update openbsp.invitations
  set status = 'accepted'
  where id = inv.id;

  return agent_id;
end;
$$;

create or replace function openbsp.reject_invitation(invitation_id uuid) returns void
language plpgsql
security definer
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  caller_email text := auth.jwt()->>'email';
begin
  if caller_email is null then
    raise exception 'authentication required'
      using errcode = '42501';
  end if;

  update openbsp.invitations
  set status = 'rejected'
  where id = invitation_id
    and status = 'pending'
    and lower(email) = lower(caller_email);

  if not found then
    raise exception 'no pending invitation for this account'
      using errcode = '42501';
  end if;
end;
$$;


-- ------------------------------------------------------------
-- File: 04_functions_post_tables/04-04_dispatch.sql
-- ------------------------------------------------------------

-- Stamps a dispatched message with the id the service gave it and merges in
-- the dispatch status, folding in any row a webhook created first for that
-- id: a status or an echo can arrive before the dispatcher has written the
-- id, and the webhook then upserts a status-only row of its own.
--
-- One transaction, so a webhook landing mid-merge cannot slip a new row in:
-- its upsert waits on the unique index for this transaction, then finds our
-- row holding the id and updates it.
--
-- Says whether it folded a webhook's row in.
--
-- Security invoker: members may neither update nor delete messages (05-05),
-- so only the service role gets anything done with it.
create or replace function openbsp.commit_dispatched_message(
  message_id uuid,
  status jsonb,
  external_id text default null -- absent when the send yields no id to track
) returns boolean
language plpgsql
security invoker
set search_path to openbsp, auth, extensions, pg_catalog
as $$
declare
  _duplicate_status jsonb;
begin
  if commit_dispatched_message.external_id is not null then
    delete from openbsp.messages m
    where m.external_id = commit_dispatched_message.external_id
      and m.id <> commit_dispatched_message.message_id
    returning m.status into _duplicate_status;
  end if;

  -- The caller's keys win over the duplicate's; the set_status trigger then
  -- merges the result into our row's status.
  update openbsp.messages m
  set
    external_id = coalesce(commit_dispatched_message.external_id, m.external_id),
    status = coalesce(_duplicate_status, '{}'::jsonb)
      || commit_dispatched_message.status
  where m.id = commit_dispatched_message.message_id;

  return _duplicate_status is not null;
end;
$$;


-- ------------------------------------------------------------
-- File: 05_rls/05-00_organizations_rls.sql
-- ------------------------------------------------------------

alter table openbsp.organizations enable row level security;

create policy "users can create orgs"
on openbsp.organizations
for insert
to authenticated -- orgs cannot be created by api keys
with check (
  true
);

create policy "members can read their orgs"
on openbsp.organizations
for select
to authenticated, anon
using (
  id in (
    select openbsp.get_authorized_orgs('member')
  )
);

-- The whole row, name included; deletion below is what stays owner-only.
create policy "admins can update their orgs"
on openbsp.organizations
for update
to authenticated, anon
using (
  id in (
    select openbsp.get_authorized_orgs('admin')
  )
)
with check (
  id in (
    select openbsp.get_authorized_orgs('admin')
  )
);

create policy "owners can delete their orgs"
on openbsp.organizations
for delete
to authenticated, anon
using (
  id in (
    select openbsp.get_authorized_orgs('owner')
  )
);

-- ------------------------------------------------------------
-- File: 05_rls/05-01_organizations_addresses_rls.sql
-- ------------------------------------------------------------

alter table openbsp.organizations_addresses enable row level security;

-- Note: organizations addresses are read only. They are managed by the system.

create policy "members can read their orgs addresses"
on openbsp.organizations_addresses
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
);

-- ------------------------------------------------------------
-- File: 05_rls/05-02_contacts_addresses_rls.sql
-- ------------------------------------------------------------

alter table openbsp.contacts_addresses enable row level security;

-- A contact row is an entry in one connection's address book, so every policy
-- applies the ACCOUNT rule via get_visible_addresses(): shared inboxes
-- (ownerless accounts) are org-wide, a personal connection's contacts belong
-- to its owner — same rule the account's conversations follow. The org filter
-- is redundant with the visibility set but kept for symmetry with the other
-- policies (and as belt-and-braces, see 04-02).

create policy "members can read visible contacts addresses"
on openbsp.contacts_addresses
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and (organization_id, service, organization_address) in (
    select v.organization_id, v.service, v.address
    from openbsp.get_visible_addresses() v
  )
);

-- Members can insert addresses (BUT NOT synced "add" ones)
create policy "members can insert contacts addresses"
on openbsp.contacts_addresses
for insert
to authenticated, anon
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and (organization_id, service, organization_address) in (
    select v.organization_id, v.service, v.address
    from openbsp.get_visible_addresses() v
  )
  and (extra->'synced'->>'action') is distinct from 'add'
);

-- Members can update non-synced addresses. Synced entries mirror the
-- service's address book — only the service writes them, same rule as
-- insert/delete below; the with check keeps a member from turning a row
-- into a synced one.
create policy "members can update non-synced contacts addresses"
on openbsp.contacts_addresses
for update
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and (organization_id, service, organization_address) in (
    select v.organization_id, v.service, v.address
    from openbsp.get_visible_addresses() v
  )
  and (extra->'synced'->>'action') is distinct from 'add'
)
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and (organization_id, service, organization_address) in (
    select v.organization_id, v.service, v.address
    from openbsp.get_visible_addresses() v
  )
  and (extra->'synced'->>'action') is distinct from 'add'
);

-- Members can delete non-synced addresses
create policy "members can delete non-synced contacts addresses"
on openbsp.contacts_addresses
for delete
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and (organization_id, service, organization_address) in (
    select v.organization_id, v.service, v.address
    from openbsp.get_visible_addresses() v
  )
  and (extra->'synced'->>'action') is distinct from 'add'
);


-- ------------------------------------------------------------
-- File: 05_rls/05-03_conversations_rls.sql
-- ------------------------------------------------------------

alter table openbsp.conversations enable row level security;

-- A conversation is a MIRROR of state that lives on someone else's server: a
-- Slack channel, a WhatsApp chat. Renaming one here does not rename it there,
-- deleting one here does not leave the channel — it just drops our copy, and
-- takes the messages with it (messages.conversation_id cascades). So members
-- get SELECT and nothing else on every service but `local`.
--
-- It is also why `extra` needs no protection of its own. Facts the ingestor
-- owns (is_bot_member, channel_archived, topic, purpose) sit in the same bag
-- as cosmetic ones and stay safe, because no API role holds UPDATE here at
-- all — for the same reason `type` is safe.
--
-- Creation is not granted either. A member starts a conversation by inserting
-- the first MESSAGE; before_insert_on_messages (SECURITY DEFINER) mints the
-- conversation row. That keeps one path for "this chat now exists" instead of
-- two, and means a member cannot pre-seed a row for, say, a Slack channel the
-- bot has not joined. Services that cannot be initiated at all (Instagram,
-- which only allows replies inside its window) fail in the dispatcher, where
-- the real rule lives — not here.
create policy "members can read their orgs conversations"
on openbsp.conversations
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  -- Account rule, minus the restricted set; or participation. All three
  -- subqueries are InitPlans (evaluated once, then hash-probed per row). See
  -- 04-02_visibility_helpers.sql.
  and (
    (
      (organization_id, service, organization_address) in (
        select v.organization_id, v.service, v.address
        from openbsp.get_visible_addresses() v
      )
      and id not in (select openbsp.get_restricted_conversations())
    )
    or id in (select openbsp.get_participant_conversations())
  )
);

-- `local` is ours, so the mirror argument does not apply: there is no other
-- server holding the truth. Members create, rename, retype and delete their
-- own internal conversations directly.
--
-- INSERT cannot test visibility (the row does not exist yet, and its
-- participants are written by the after-insert trigger), so it checks only
-- that the caller is a member of the org. UPDATE and DELETE reuse the SELECT
-- rule: you may change what you can see.
create policy "members can create their orgs local conversations"
on openbsp.conversations
for insert
to authenticated, anon
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and service = 'local'::openbsp.service
);

create policy "members can update their orgs local conversations"
on openbsp.conversations
for update
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and service = 'local'::openbsp.service
  and (
    (
      (organization_id, service, organization_address) in (
        select v.organization_id, v.service, v.address
        from openbsp.get_visible_addresses() v
      )
      and id not in (select openbsp.get_restricted_conversations())
    )
    or id in (select openbsp.get_participant_conversations())
  )
)
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and service = 'local'::openbsp.service
);

create policy "members can delete their orgs local conversations"
on openbsp.conversations
for delete
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  and service = 'local'::openbsp.service
  and (
    (
      (organization_id, service, organization_address) in (
        select v.organization_id, v.service, v.address
        from openbsp.get_visible_addresses() v
      )
      and id not in (select openbsp.get_restricted_conversations())
    )
    or id in (select openbsp.get_participant_conversations())
  )
);


-- ------------------------------------------------------------
-- File: 05_rls/05-04_agents_rls.sql
-- ------------------------------------------------------------

-- EVERY with-check restates its own authority test, and that is not
-- redundancy with the using clause above it. Permissive policies OR by CLAUSE,
-- not by policy: the new row is accepted if ANY policy's with-check passes,
-- whether or not that policy's using clause is what admitted the row. A
-- with-check that only pins columns therefore hands its permission to every
-- other policy on the table.
--
-- That is exactly how a member could promote themselves before this file was
-- rewritten. "owners can update their orgs agents" checked `using (owner)` but
-- its with-check was the column pin alone, and the column pin said nothing
-- about role — so a member selected their own row through "members can update
-- themselves", set role to owner, failed that policy's with-check, and passed
-- the owner policy's. Fixed here; see the CHANGELOG.
--
-- The whole model, in one place: you see everyone in your organizations, you
-- edit yourself, admins edit anyone and run the AI roster, owners do
-- anything, and you can leave. Only owners grant roles and remove people —
-- control over PEOPLE is the owner's line, and `user_id is null` is how these
-- policies draw it: an AI agent is staff, not membership.

alter table openbsp.agents enable row level security;

create policy "members can read their orgs agents"
on openbsp.agents
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
);

-- Name, picture, extra. Not your own role — that is the whole point of the
-- role check in the helper.
create policy "members can update themselves"
on openbsp.agents
for update
to authenticated
using (
  user_id = (select auth.uid())
)
with check (
  user_id = (select auth.uid())
  and openbsp.agent_identity_and_role_unchanged(id, user_id, organization_id, role)
);

-- Admins maintain the roster: renaming a colleague, retiring an AI agent's
-- prompt. Everything except who anyone is and what they may do.
create policy "admins can update their orgs agents"
on openbsp.agents
for update
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
)
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
  and openbsp.agent_identity_and_role_unchanged(id, user_id, organization_id, role)
);

-- `user_id is null` here is what makes invitations the only door for people.
-- An admin may mint AI agents freely; conjuring a row that names a human
-- would hand that person a membership they never accepted. The two paths that
-- legitimately insert a row with a user_id — organization creation and
-- accept_invitation — are SECURITY DEFINER and never see this policy.
create policy "admins can create their orgs ai agents"
on openbsp.agents
for insert
to authenticated, anon
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
  and user_id is null
);

-- The AI half of the delete below, at admin. Removing a PERSON stays with
-- owners: it is membership control, like roles and invitations.
create policy "admins can delete their orgs ai agents"
on openbsp.agents
for delete
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
  and user_id is null
);

-- Owners additionally set roles. Identity still cannot move — even an owner
-- gets no tenant escape or impersonation.
create policy "owners can update their orgs agents"
on openbsp.agents
for update
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
)
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
  and openbsp.agent_identity_unchanged(id, user_id, organization_id)
);

create policy "owners can delete their orgs agents"
on openbsp.agents
for delete
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
);

-- Leaving. The delete is turned into a mark by mark_agent_deleted, and refused
-- outright by prevent_last_owner_deletion if you are the last owner — hand the
-- organization over first.
create policy "members can delete themselves"
on openbsp.agents
for delete
to authenticated
using (
  user_id = (select auth.uid())
);


-- ------------------------------------------------------------
-- File: 05_rls/05-05_messages_rls.sql
-- ------------------------------------------------------------

alter table openbsp.messages enable row level security;

-- Note: messages cannot be edited or deleted by the user.

create policy "members can read their orgs messages"
on openbsp.messages
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  -- Account rule, minus the restricted set; or
  -- participation. All three subqueries are InitPlans (evaluated once, then
  -- hash-probed per row). See 04-02_visibility_helpers.sql.
  and (
    (
      (organization_id, service, organization_address) in (
        select v.organization_id, v.service, v.address
        from openbsp.get_visible_addresses() v
      )
      and conversation_id not in (select openbsp.get_restricted_conversations())
    )
    or conversation_id in (select openbsp.get_participant_conversations())
  )
);

-- conversation_id is filled by before_insert_on_messages when missing; RLS
-- WITH CHECK runs after BEFORE triggers, so the visibility check sees it.
create policy "members can create their orgs messages"
on openbsp.messages
for insert
to authenticated, anon
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
  -- Account rule, minus the restricted set; or
  -- participation. All three subqueries are InitPlans (evaluated once, then
  -- hash-probed per row). See 04-02_visibility_helpers.sql.
  and (
    (
      (organization_id, service, organization_address) in (
        select v.organization_id, v.service, v.address
        from openbsp.get_visible_addresses() v
      )
      and conversation_id not in (select openbsp.get_restricted_conversations())
    )
    or conversation_id in (select openbsp.get_participant_conversations())
  )
);


-- ------------------------------------------------------------
-- File: 05_rls/05-06_api_keys_rls.sql
-- ------------------------------------------------------------

alter table openbsp.api_keys enable row level security;

-- Note: Self-read check is merged here (not a separate policy) because
-- get_authorized_orgs raises an exception on insufficient permissions.
-- Separate policies would fail: even if self-read passes, the owner policy's
-- exception aborts the query. Using OR short-circuits: if key matches,
-- get_authorized_orgs is never called.
create policy "owners can read their orgs api keys"
on openbsp.api_keys
for select
to authenticated, anon
using (
  -- Subselect so the header is read once per query (an InitPlan) instead of
  -- once per row. It still evaluates before the OR's right side, so the
  -- short-circuit above holds.
  key = (select current_setting('request.headers', true)::json->>'api-key')
  or organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
);

create policy "owners can create their orgs api keys"
on openbsp.api_keys
for insert
to authenticated, anon
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
);

create policy "owners can delete their orgs api keys"
on openbsp.api_keys
for delete
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
);

-- ------------------------------------------------------------
-- File: 05_rls/05-07_webhooks_rls.sql
-- ------------------------------------------------------------

alter table openbsp.webhooks enable row level security;

-- Owners only: a webhook receives the org's traffic, and its headers can
-- carry secrets — pointing one at your own server is exfiltration, so this
-- sits with API keys on the control side of the admin line.
create policy "owners can manage their orgs webhooks"
on openbsp.webhooks
for all
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
)
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
);


-- ------------------------------------------------------------
-- File: 05_rls/05-09_onboarding_tokens_rls.sql
-- ------------------------------------------------------------

alter table openbsp.onboarding_tokens enable row level security;

create policy "admins can read their org onboarding tokens"
on openbsp.onboarding_tokens
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
);

create policy "admins can create onboarding tokens"
on openbsp.onboarding_tokens
for insert
to authenticated, anon
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
);

create policy "admins can delete onboarding tokens"
on openbsp.onboarding_tokens
for delete
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('admin')
  )
);


-- ------------------------------------------------------------
-- File: 05_rls/05-10_logs_rls.sql
-- ------------------------------------------------------------

alter table openbsp.logs enable row level security;

-- Org members can read their own org's logs (Meta management events: account
-- updates, history/signup errors). No secrets are stored in logs.metadata.
create policy "members can read their orgs logs"
on openbsp.logs
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
);


-- ------------------------------------------------------------
-- File: 05_rls/05-11_objects_rls.sql
-- ------------------------------------------------------------

create policy "members can download their orgs media"
on storage.objects
for select
to authenticated, anon
using (
  bucket_id = 'media'
  and (storage.foldername(name))[2] in ( select get_authorized_orgs('member')::text ) -- message v1 path is organizations/<org_id>/attachments/<file_id>
  -- Attachments of membership-scoped conversations (e.g. a private Slack
  -- DM) are only downloadable by members who can see a referencing message;
  -- unreferenced objects (just-uploaded, legacy) stay org-scoped.
  and openbsp.is_media_visible(name)
);

create policy "members can upload their orgs media"
on storage.objects
for insert
to authenticated, anon
with check (
  bucket_id = 'media'
  and (storage.foldername(name))[2] in ( select get_authorized_orgs('member')::text ) -- message v1 path is organizations/<org_id>/attachments/<file_id>
);

-- ------------------------------------------------------------
-- File: 05_rls/05-12_conversations_agents_rls.sql
-- ------------------------------------------------------------

alter table openbsp.conversations_agents enable row level security;

-- This table does two jobs, and the difference decides every policy below:
--
--   PARTICIPATION  On a mirror service it reflects membership of the external
--                  container (a Slack channel's members), and it GRANTS
--                  VISIBILITY — it is the only way into a restricted
--                  conversation. Service-managed, therefore: a member who
--                  could insert here at will could read any private DM in the
--                  workspace by naming its id.
--
--   MEMBER STATE   A row also carries the caller's own state for the
--                  conversation (extra) — read receipts, mute.
--
-- One row does both, so a write for the second reaches the first: UPDATE
-- MOVES rows, and a row that lands on another conversation is a participation
-- its owner just granted themselves — the grant INSERT refuses, arriving by a
-- different verb. So all three write commands take the same line, drawn the
-- way 05-03 draws it on conversations: every write is `local`, where
-- participation is a thing members legitimately manage, and a mirror service
-- is read-only because the truth is on someone else's server. Mirror state
-- included: the row is the sync's, and so is what it carries.
--
-- UI preferences (archived, pinned, drafts) are not member state and do not
-- belong here. A preference has to be settable on any conversation you can
-- SEE — which is every service, and this table is writable on one.
--
-- No recursion: the conversations subqueries below run with the caller's
-- rights and are scoped by conversations RLS, which decides membership
-- through SECURITY DEFINER helpers that read this table without re-entering
-- its policies.

-- Anyone who can see a conversation can see who else is in it (the
-- participant list — same information Slack itself shows).
--
-- `to authenticated` only — no anon, unlike the other policies: anon is the
-- API-key path, and membership can never matter to an API key (the only
-- visibility branch that reads this table requires auth.uid(); API keys see
-- org-wide content only). Membership is a user concept. The table grants
-- match (select granted to authenticated, not anon).
create policy "members can read memberships of visible conversations"
on openbsp.conversations_agents
for select
to authenticated
using (
  exists (
    select 1 from openbsp.conversations c
    where c.id = conversation_id
  )
);

-- Your own row, on a local conversation you can see: editing `extra`, the
-- one column here that is nobody else's business. The visibility test is the
-- plain one — no group/channel split like the two policies below — because
-- this command adds nobody: whichever way you got the row, changing your own
-- state on it changes nothing about who is in the room.
--
-- WITH CHECK re-tests every half, so the row cannot be re-pointed — not at
-- another agent, not at a conversation you cannot see, and not off `local`.
-- (The participation branch of that test reads this table's pre-statement
-- snapshot, so a row cannot bootstrap its own visibility by moving.)
create policy "members can update their own local membership rows"
on openbsp.conversations_agents
for update
to authenticated
using (
  agent_id in (select openbsp.get_own_agents())
  and exists (
    select 1 from openbsp.conversations c
    where c.id = conversation_id
      and c.service = 'local'::openbsp.service
  )
)
with check (
  agent_id in (select openbsp.get_own_agents())
  and exists (
    select 1 from openbsp.conversations c
    where c.id = conversation_id
      and c.service = 'local'::openbsp.service
  )
);

-- Adding someone to a group, and joining a channel — the two acts the delete
-- policy below undoes, so this is its mirror image: one policy, the same two
-- branches.
--
-- `local` only, like every other write here. A Slack membership is Slack's
-- fact, written by the sync and the webhook with the service role, and a row
-- a member wrote for themselves would desync us until the next sync
-- overwrote it.
--
-- A row for yourself on a conversation that is visible WITHOUT participation
-- is not an exception worth carving out, however harmless it looks: it grants
-- nothing only for as long as the other branch holds. Visibility is `(account
-- rule and not restricted) or participation`, and the two are independent, so
-- when a Slack channel stops being shared because the bot left it, the
-- account branch fails for the whole organization and a self-written row is
-- what keeps its author reading the history everyone else just lost.
--
-- `direct` is absent on purpose, at any size: its roster IS its identity (it
-- is literally its address), so adding a person would not extend the
-- conversation, it would name a different one. Starting that conversation is
-- how you get it.
--
-- One policy, not two, because permissive with-checks OR across every policy
-- on the command (see the header on 05-04): each half would have to restate
-- the other's authority test to avoid handing its permission over.
create policy "members can create local membership rows"
on openbsp.conversations_agents
for insert
to authenticated
with check (
  exists (
    select 1 from openbsp.conversations c
    where c.id = conversation_id
      and c.service = 'local'::openbsp.service
      and (
        -- Adding: a group you are in. There are no roles yet, so this is
        -- deliberately flat. "You can only add people to rooms you are in" —
        -- stated, not implied: a clause describing only the SHAPE of the
        -- target would let any authenticated user add anyone to any local
        -- group in the database, other tenants' included.
        (
          c.type = 'group'
          and conversation_id in (select openbsp.get_participant_conversations())
        )
        -- Joining: self-service, since a local channel is open to the
        -- organization by shape. Naming your own agent is the authority.
        or (
          c.type = 'channel'
          and agent_id in (select openbsp.get_own_agents())
        )
      )
  )
);

-- Kicking (local groups) and leaving (local channels). Same rosters-are-fixed
-- rule as above: there is no leaving a direct, because the room
-- without you is a different room.
--
-- Mirror services are absent: a Slack membership row is Slack's fact, and
-- deleting it here would only desync us until the next sync put it back.
create policy "members can delete local membership rows"
on openbsp.conversations_agents
for delete
to authenticated
using (
  exists (
    select 1 from openbsp.conversations c
    where c.id = conversation_id
      and c.service = 'local'::openbsp.service
      and (
        -- Kicking: same rule as adding, and for the same reason — shape alone
        -- would let anyone empty any group in the database.
        (
          c.type = 'group'
          and conversation_id in (select openbsp.get_participant_conversations())
        )
        -- Leaving: naming your own agent is the authority.
        or (
          c.type = 'channel'
          and agent_id in (select openbsp.get_own_agents())
        )
      )
  )
);


-- ------------------------------------------------------------
-- File: 05_rls/05-13_invitations_rls.sql
-- ------------------------------------------------------------

alter table openbsp.invitations enable row level security;

-- Everyone in the organization sees its invitations, because the members list
-- shows pending ones alongside members — which is how it worked when an
-- invitation WAS an agents row covered by "members can read their orgs
-- agents".
create policy "members can read their orgs invitations"
on openbsp.invitations
for select
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('member')
  )
);

-- The invitee, who is by definition not in the organization yet and so cannot
-- reach the policy above. Matched on the JWT's email: an API key authenticates
-- without one, so `anon` is absent here on purpose.
--
-- Only pending rows. There is no reason to hand someone the history of offers
-- they already answered, and the partial index is on the same predicate.
create policy "invitees can read their own invitations"
on openbsp.invitations
for select
to authenticated
using (
  status = 'pending'
  and lower(email) = lower((select auth.jwt()->>'email'))
);

-- Sending, editing, revoking and deleting — owners only, matching who may
-- manage agents. Note that this deliberately does NOT let an owner mark an
-- invitation accepted into existence: status is bookkeeping, and membership
-- comes from an agents row, which only accept_invitation() writes.
create policy "owners can manage their orgs invitations"
on openbsp.invitations
for all
to authenticated, anon
using (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
)
with check (
  organization_id in (
    select openbsp.get_authorized_orgs('owner')
  )
);


-- ====================================================================
-- 4. Função auxiliar para configurar as variáveis do Vault
-- ====================================================================

CREATE OR REPLACE FUNCTION openbsp.configure_vault(
  p_edge_functions_url text,
  p_service_role_key text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- edge_functions_url
  IF EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'edge_functions_url') THEN
    PERFORM vault.update_secret(
      (SELECT id FROM vault.decrypted_secrets WHERE name = 'edge_functions_url'),
      p_edge_functions_url,
      'edge_functions_url',
      'OpenBSP Edge Functions Base URL'
    );
  ELSE
    PERFORM vault.create_secret(
      p_edge_functions_url,
      'edge_functions_url',
      'OpenBSP Edge Functions Base URL'
    );
  END IF;

  -- edge_functions_token
  IF EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'edge_functions_token') THEN
    PERFORM vault.update_secret(
      (SELECT id FROM vault.decrypted_secrets WHERE name = 'edge_functions_token'),
      p_service_role_key,
      'edge_functions_token',
      'OpenBSP Service Role Key'
    );
  ELSE
    PERFORM vault.create_secret(
      p_service_role_key,
      'edge_functions_token',
      'OpenBSP Service Role Key'
    );
  END IF;
END;
$$;

-- ====================================================================
-- 5. Função auxiliar para inicializar a Primeira Organização e API Key
-- ====================================================================

CREATE OR REPLACE FUNCTION openbsp.create_initial_organization(
  p_org_name text,
  p_api_key text DEFAULT NULL,
  p_user_email text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_org_id uuid := gen_random_uuid();
  v_user_id uuid := NULL;
  v_agent_id uuid := gen_random_uuid();
  v_key text := coalesce(p_api_key, encode(gen_random_bytes(24), 'hex'));
BEGIN
  INSERT INTO openbsp.organizations (id, name)
  VALUES (v_org_id, p_org_name);

  IF p_user_email IS NOT NULL THEN
    SELECT id INTO v_user_id FROM auth.users WHERE email = lower(trim(p_user_email)) LIMIT 1;
  END IF;

  INSERT INTO openbsp.agents (id, organization_id, user_id, name, role)
  VALUES (v_agent_id, v_org_id, v_user_id, p_org_name || ' Admin', 'owner');

  INSERT INTO openbsp.api_keys (organization_id, key, role, name)
  VALUES (v_org_id, v_key, 'owner', 'Default API Key');

  RETURN jsonb_build_object(
    'organization_id', v_org_id,
    'agent_id', v_agent_id,
    'user_id', v_user_id,
    'api_key', v_key
  );
END;
$$;

-- Permissões finais
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA openbsp TO anon, authenticated, service_role, postgres;
