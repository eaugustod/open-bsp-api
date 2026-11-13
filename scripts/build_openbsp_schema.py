#!/usr/bin/env python3
import os
import re

SCHEMA_DIR = "supabase/schemas"

files_order = [
    # Extensions & Schema
    "01_types.sql",
    "02_functions/02-01_json_utils.sql",
    "02_functions/02-02_edge_functions.sql",
    "02_functions/02-03_trigger_functions.sql",
    "02_functions/02-04_rcp_functions.sql",
    "02_functions/02-05_text_limits.sql",
    "03_models/03-00_organizations.sql",
    "03_models/03-01_organizations_addresses.sql",
    "03_models/03-02_contacts_addresses.sql",
    "03_models/03-03_conversations.sql",
    "03_models/03-04_agents.sql",
    "03_models/03-05_messages.sql",
    "03_models/03-06_api_keys.sql",
    "03_models/03-07_webhooks.sql",
    "03_models/03-10_logs.sql",
    "03_models/03-11_onboarding_tokens.sql",
    "03_models/03-13_conversations_agents.sql",
    "03_models/03-14_invitations.sql",
    "03_models/03-12_auth.users.sql",
    "04_functions_post_tables/04-01_auth_helpers.sql",
    "04_functions_post_tables/04-02_visibility_helpers.sql",
    "04_functions_post_tables/04-03_invitations.sql",
    "04_functions_post_tables/04-04_dispatch.sql",
    "05_rls/05-00_organizations_rls.sql",
    "05_rls/05-01_organizations_addresses_rls.sql",
    "05_rls/05-02_contacts_addresses_rls.sql",
    "05_rls/05-03_conversations_rls.sql",
    "05_rls/05-04_agents_rls.sql",
    "05_rls/05-05_messages_rls.sql",
    "05_rls/05-06_api_keys_rls.sql",
    "05_rls/05-07_webhooks_rls.sql",
    "05_rls/05-09_onboarding_tokens_rls.sql",
    "05_rls/05-10_logs_rls.sql",
    "05_rls/05-11_objects_rls.sql",
    "05_rls/05-12_conversations_agents_rls.sql",
    "05_rls/05-13_invitations_rls.sql",
]

header = """-- ====================================================================
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

"""

footer = """
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
"""

combined = [header]

for rel_path in files_order:
    full_path = os.path.join(SCHEMA_DIR, rel_path)
    if not os.path.exists(full_path):
        print(f"Warning: {full_path} not found!")
        continue
    
    with open(full_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Replace "public". or public. with openbsp.
    # Be careful not to replace auth.users, storage., vault., net., etc.
    content = re.sub(r'\bpublic\.', 'openbsp.', content)
    content = re.sub(r'"public"\.', '"openbsp".', content)
    
    # Secure and correct search_path inside functions
    content = re.sub(r"set\s+search_path\s+to\s+''", "set search_path to openbsp, auth, extensions, pg_catalog", content, flags=re.IGNORECASE)

    # Safely create or replace functions
    content = re.sub(r'\bcreate\s+function\s+', 'create or replace function ', content, flags=re.IGNORECASE)

    # Safely wrap CREATE TYPE in exception handlers to prevent duplicate_object errors
    if "01_types.sql" in rel_path:
        # Wrap each create type statement in a DO block
        pattern = re.compile(r'(create\s+type\s+openbsp\.\w+\s+as\s+enum\s*\([^;]+;\s*)', re.IGNORECASE)
        def wrap_type(m):
            stmt = m.group(1).strip()
            return f"DO $$ BEGIN\n  {stmt}\nEXCEPTION WHEN duplicate_object THEN NULL;\nEND $$;\n"
        content = pattern.sub(wrap_type, content)

    if "03-12_auth.users.sql" in rel_path:
        content = "DROP TRIGGER IF EXISTS prevent_owner_user_deletion ON auth.users;\n" + content
    
    # Handle moddatetime extension reference if in public
    # if moddatetime was loaded into extensions or public
    combined.append(f"\n-- ------------------------------------------------------------\n-- File: {rel_path}\n-- ------------------------------------------------------------\n")
    combined.append(content)

combined.append(footer)

out_file = "openbsp_setup.sql"
with open(out_file, "w", encoding="utf-8") as f:
    f.write("\n".join(combined))

print(f"Generated {out_file} successfully ({len(''.join(combined))} bytes).")
