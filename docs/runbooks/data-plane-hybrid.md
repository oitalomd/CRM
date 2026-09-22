# Data plane híbrido do DeskcommCRM

## Decisão

O Supabase Cloud permanece como control plane: autenticação, sessões, OAuth,
organizações, membros, permissões e Storage. O PostgreSQL com pgvector na VPS
é um data plane operacional dedicado por organização.

O banco operacional não recebe senhas, refresh tokens ou segredos de sessão.
Ele mantém somente as identidades dos membros necessárias para FKs, auditoria e
consultas operacionais. A sincronização é feita a partir do Supabase Cloud no
gate de promoção.

## Fluxo de uma organização

1. Criar o PostgreSQL com pgvector em um projeto isolado da VPS.
2. Expor PostgREST apenas na rede interna ou atrás do proxy existente; nunca
   publicar a porta do banco.
3. Registrar a URI PostgreSQL, a URL PostgREST e a chave operacional no
   `organization_data_planes`, sempre cifradas.
4. Executar o gate de promoção. Ele instala o prelude, o contrato operacional
   e o baseline idempotente.
5. Sincronizar somente os membros daquela organização do Auth Cloud.
6. Validar schema, extensão `vector`, contrato, consultas básicas e isolamento.
7. Marcar o data plane como `ready` somente depois de todas as verificações.

## Regras de segurança

- `TENANCY_REQUIRE_DEDICATED` permanece desligado durante a migração gradual.
- Uma organização sem data plane continua no Supabase compartilhado até ser
  promovida; uma organização com data plane em `provisioning`, `failed` ou
  `degraded` não recebe tráfego dedicado.
- O Supabase Cloud continua sendo usado para login e Storage. O Postgres local
  não deve ser tratado como um segundo sistema de autenticação.
- Backups e restauração devem ser testados antes de qualquer migração de dados.
- A produção atual não deve ser alterada para criar o primeiro canary.

## Critérios de aceite do canary

- segunda execução do prelude e do baseline sem erro;
- `vector`, `uuid-ossp`, `pgcrypto`, `citext` e `pg_trgm` disponíveis;
- contrato `public.deskcomm_operational_contract` com origem `supabase-cloud`;
- somente membros da organização presentes em `auth.users` local;
- nenhuma senha, refresh token ou segredo de sessão copiado;
- uma consulta de escrita/leitura real pelo endpoint PostgREST;
- teste negativo comprovando que uma organização não lê o banco de outra;
- backup, restauração e rollback observados em ambiente isolado.

Sem esses critérios, o provider PostgreSQL não deve ser marcado como `ready`.

