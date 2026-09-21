# ADR: isolamento de dados por banco de organização

## Status

Proposto. Não aplicar diretamente na instalação de produção.

## Contexto

O DeskcommCRM já possui o conceito de organização: `organizations`,
`user_organizations`, `organization_id` nas entidades de negócio e políticas
de Row Level Security. Isso implementa isolamento lógico em um Supabase
compartilhado.

O requisito novo é isolamento físico/lógico forte por organização, com um
PostgreSQL separado para cada tenant. Essa mudança não pode ser feita apenas
alterando `SUPABASE_DB_URL`: o código atual possui clientes Supabase globais,
rotas, workers, realtime, storage e jobs que assumem um único projeto.

## Decisão proposta

Adotar uma arquitetura de dois planos:

1. **Control plane**: o Supabase atual mantém autenticação, usuários,
   organizações, membros, estado de provisionamento e o catálogo de conexões.
2. **Data plane**: cada organização recebe um projeto/banco Supabase dedicado
   (PostgreSQL compatível com os schemas e extensões usados pelo Deskcomm),
   identificado por um registro no control plane. Dados operacionais do CRM,
   conversas, contatos, pipelines, configurações, IA e auditoria do tenant
   ficam no banco dedicado.
3. **Roteamento por requisição**: a organização ativa é resolvida a partir da
   sessão e do vínculo validado; o cliente do data plane é criado a partir do
   registro confiável do tenant, nunca de um `organization_id` enviado pelo
   navegador.
4. **Workers**: jobs carregam `organization_id` e resolvem o banco antes de
   executar. Nenhum worker pode usar um cliente global para dados de negócio.
5. **Migrações**: uma versão de schema é aplicada idempotentemente a cada
   banco novo e a cada upgrade. O provisionamento só conclui quando o banco
   passa pelo health check e pela versão mínima.
6. **Arquivos e integrações**: caminhos de storage, tokens cifrados, filas,
   webhooks e conexões externas recebem escopo explícito de organização.

## Por que não fazer uma conversão direta

Há centenas de pontos que usam `createClient` ou `createAdminClient`. Uma
substituição mecânica deixaria rotas e workers misturando bancos, quebraria
transações e criaria risco de vazamento entre tenants. A migração deve ser
incremental, com uma camada de resolução de tenant, testes de isolamento e
dual-read/dual-write apenas onde houver uma migração de dados real.

## Fases obrigatórias

1. Corrigir onboarding e garantir que toda conta normal tenha organização.
2. Criar control plane e registro de provisionamento, sem alterar o banco de
   produção.
3. Extrair o acesso ao data plane para uma interface única e torná-la
   request-scoped.
4. Migrar primeiro um tenant de teste para um projeto/banco Supabase dedicado.
5. Rodar testes de isolamento positivo e negativo, workers, realtime, storage,
   webhooks e migrações repetidas.
6. Migrar a organização atual em janela controlada, com backup e rollback.
7. Migrar novos tenants automaticamente e aposentar o caminho compartilhado
   somente após a verificação de todos os tenants.

## Critérios de aceitação

- uma sessão de A nunca consegue ler ou escrever dados de B;
- uma falha no banco de A não derruba B nem o control plane;
- o provisionamento é repetível e recuperável;
- uma nova versão de schema pode ser aplicada sem intervenção manual em cada
  organização;
- backup e restauração funcionam por organização;
- o deploy publicado tem imagem versionada e rollback para a imagem atual;
- a produção só muda depois de smoke tests públicos e validação de containers.

## Risco operacional conhecido

A imagem `ghcr.io/melgarafael/deskcommcrm:stable` não contém esta arquitetura.
O deploy precisa usar uma imagem própria construída e publicada com tag
imutável. A VPS atual deve permanecer apontando para a imagem estável até a
homologação terminar.

## Compatibilidade do data plane

O `supabase/baseline.sql` atual é um baseline completo do ecossistema Supabase:
ele usa `auth`, `storage`, `extensions` e extensões como `pgvector`. Portanto,
uma instância PostgreSQL vanilla não é um data plane válido para o código atual.
O provisionador deve rejeitar conexões sem esses pré-requisitos antes de
executar SQL. Não é permitido criar schemas/tabelas falsos para simular os
serviços internos do Supabase. Se PostgreSQL vanilla for uma exigência futura,
será necessário primeiro publicar um baseline de negócio independente, sem
dependências de autenticação/storage do Supabase.

