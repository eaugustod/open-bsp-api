# 🚀 Guia de Implantação: OpenBSP no Coolify com Supabase Compartilhado (Schema `openbsp`)

Este guia contém as instruções passo a passo para colocar o **OpenBSP 100% funcional** na sua VPS via Coolify, compartilhando o mesmo PostgreSQL do Supabase do ClinicFlow sem sobrecarregar a memória RAM.

---

## 📋 Sumário da Arquitetura Adaptada

- **Schema Isolado (`openbsp`)**: Todas as tabelas, tipos e funções foram migrados para o schema `openbsp`, não interferindo nas tabelas do `clinicflow` no schema `public`.
- **Container Híbrido Leve**: Um único container Docker roda o backend (Edge Functions/Deno Gateway) e entrega a interface Web (React/Tailwind), consumindo menos de 80 MB de memória RAM.
- **Porta padrão**: `8080`.

---

## Passo 1: Habilitar o schema `openbsp` no PostgREST do Supabase

Por padrão, a API REST do Supabase só expõe o schema `public`. Precisamos liberar o schema `openbsp`.

1. No painel do **Coolify**, acesse o serviço do **Supabase**.
2. Abra as configurações de variáveis de ambiente do serviço Supabase (ou do container `supabase-rest` / `postgrest`).
3. Localize a variável `PGRST_DB_SCHEMAS`.
4. Adicione `,openbsp` ao valor existente. Exemplo:
   ```env
   PGRST_DB_SCHEMAS=public,storage,graphql_public,openbsp
   ```
5. Salve e clique em **Redeploy** ou **Restart** no Supabase.

---

## Passo 2: Executar o Script de Banco de Dados no Supabase Studio

1. Abra o **Supabase Studio** no navegador:
   `https://supabase.erpclinicflow.cloud/project/default`
2. No menu lateral esquerdo, clique em **SQL Editor** -> **New Query**.
3. Abra o arquivo [`openbsp_setup.sql`](openbsp_setup.sql) gerado na raiz deste projeto, copie todo o seu conteúdo e cole no SQL Editor.
4. Clique no botão **Run** (Executar).
5. Após concluir com sucesso, crie uma nova aba no SQL Editor e execute a configuração inicial:

```sql
-- 1. Configurar os segredos do Vault para os gatilhos saberem onde chamar sua API:
-- Substitua 'https://openbsp.erpclinicflow.cloud' pelo domínio que usará no Coolify
-- Substitua 'SEU_SERVICE_ROLE_KEY' pela sua service_role_key do Supabase
SELECT openbsp.configure_vault(
  'https://openbsp.erpclinicflow.cloud',
  'SEU_SERVICE_ROLE_KEY'
);

-- 2. Criar a sua Organização e Chave de API inicial:
-- Substitua pelo nome da sua organização e, opcionalmente, seu email do Supabase
SELECT openbsp.create_initial_organization(
  'ClinicFlow',
  'cf_secret_key_whatsapp_2026', -- Você pode definir sua chave ou deixar NULL para gerar uma aleatória
  'seu-email@dominio.com'         -- Seu email de usuário do Supabase (opcional)
);
```

> 💡 Guarde o `organization_id` e a `api_key` retornados pelo comando acima.

---

## Passo 3: Configurar a Aplicação OpenBSP no Coolify

1. No painel do **Coolify**, clique em **+ Create New Resource** -> **Application**.
2. Aponte para o repositório Git onde estão estes arquivos (ou suba via Git/Docker).
3. Selecione o tipo de build: **Dockerfile**.
4. Configure a porta: **`8080`**.
5. Configure o domínio público:
   - Exemplo: `https://openbsp.erpclinicflow.cloud`
6. Nas **Variáveis de Ambiente (Environment Variables)** no Coolify, adicione:

```env
# Conexão com Supabase
SUPABASE_URL=https://supabase.erpclinicflow.cloud
SUPABASE_ANON_KEY=sua_anon_key_aqui
SUPABASE_SERVICE_ROLE_KEY=sua_service_role_key_aqui
SUPABASE_DB_SCHEMA=openbsp
PORT=8080

# Credenciais da Meta / WhatsApp Cloud API
WHATSAPP_VERIFY_TOKEN=clinicflow_verify_token_2026
META_APP_ID=seu_app_id_da_meta
META_APP_SECRET=seu_app_secret_da_meta
META_SYSTEM_USER_ACCESS_TOKEN=seu_access_token_do_system_user

# Argumentos de Build para o Frontend Web (open-bsp-ui)
VITE_SUPABASE_URL=https://supabase.erpclinicflow.cloud
VITE_SUPABASE_ANON_KEY=sua_anon_key_aqui
VITE_SUPABASE_SCHEMA=openbsp
VITE_META_APP_ID=seu_app_id_da_meta
```

7. Clique em **Deploy**.

---

## Passo 4: Configurar o Webhook no Painel de Desenvolvedores da Meta

1. Acesse o portal [Meta for Developers](https://developers.facebook.com/apps).
2. Selecione o seu App do WhatsApp -> **WhatsApp** -> **Configuration**.
3. Na seção **Webhooks**, clique em **Edit**:
   - **Callback URL**: `https://openbsp.erpclinicflow.cloud/whatsapp-webhook`
   - **Verify Token**: `clinicflow_verify_token_2026` (o mesmo valor que você colocou na variável `WHATSAPP_VERIFY_TOKEN` no Coolify)
4. Clique em **Verify and Save**.
5. Em **Webhook fields**, clique em **Manage** e assine o campo:
   - ✅ **`messages`**

---

## Passo 5: Conectar seu Número no WhatsApp

Existem duas formas de vincular o número:

### Opção A: Pelo painel Web do OpenBSP
1. Abra `https://openbsp.erpclinicflow.cloud` no navegador.
2. Faça login com o seu usuário do Supabase.
3. Acesse **Integrations** -> **WhatsApp** e conecte seu número.

### Opção B: Direto pelo SQL (mais rápido se você já tiver o Phone Number ID e Token da Meta)
```sql
INSERT INTO openbsp.organizations_addresses (
  organization_id,
  service,
  address,        -- Phone Number ID da Meta (ex: '109823471923')
  status,
  extra
) VALUES (
  'SEU_ORGANIZATION_ID',
  'whatsapp',
  'SEU_PHONE_NUMBER_ID',
  'connected',
  jsonb_build_object(
    'phone_number', '5511999999999',
    'access_token', 'SEU_ACCESS_TOKEN_DA_META',
    'waba_id', 'SEU_WABA_ID'
  )
);
```

---

## 🎯 Teste de Envio e Recebimento

### Enviar Mensagem via API:
```bash
curl -X POST 'https://supabase.erpclinicflow.cloud/rest/v1/messages' \
  -H 'apikey: SUA_ANON_KEY' \
  -H 'api-key: SUA_CHAVE_OPENBSP' \
  -H 'Content-Type: application/json' \
  -H 'Profile: openbsp' \
  -H 'Content-Profile: openbsp' \
  -d '{
    "organization_id": "SEU_ORGANIZATION_ID",
    "organization_address": "SEU_PHONE_NUMBER_ID",
    "conversation_address": "5511999999999",
    "service": "whatsapp",
    "content": {
      "version": "1",
      "type": "text",
      "kind": "text",
      "text": "Olá! Teste do OpenBSP funcionando 100% no Coolify!"
    }
  }'
```

