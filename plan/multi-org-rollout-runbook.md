# Runbook de rollout multi-organização

Este runbook é obrigatório antes de alterar a instalação `deskcommcrm` em
produção. O objetivo é permitir uma migração reversível, sem trocar a imagem
`ghcr.io/melgarafael/deskcommcrm:stable` até que o canário esteja aprovado.

## 1. Pré-condições

- PR revisado e branch construída com uma tag imutável de imagem; nunca usar
  `latest` ou substituir `stable` durante o canário.
- Backup verificável do control plane e do banco compartilhado atual.
- Registro do tenant com `status=provisioning`, credenciais cifradas e
  `schema_version=0`; nenhum tráfego é enviado enquanto não estiver `ready`.
- Data plane compatível com Supabase, `pgvector`, `auth`, `storage` e
  `extensions`. PostgreSQL vanilla é recusado pelo gate de compatibilidade.

## 2. Gate de promoção do tenant

Executar o fluxo de registro e promoção para um tenant de homologação:

1. validar conectividade e permissões;
2. aplicar `supabase/baseline.sql` de forma idempotente e transacional;
3. confirmar `schema_version` e o hash do schema;
4. executar `select 1` e consultas mínimas de CRM;
5. marcar o registro como `ready` somente depois de todos os passos;
6. em qualquer falha, fechar o pool e manter o tenant fora do tráfego.

O teste deve ser repetido uma segunda vez. A segunda execução precisa ser
idempotente e não pode duplicar dados ou registros de schema.

## 3. Canário

- Usar uma organização de teste isolada, nunca a organização produtiva.
- Validar login, contatos, conversas, mensagens, funil, agenda, workers,
  mídia, LGPD, realtime, webhooks e storage.
- Confirmar isolamento negativo: uma sessão de A não encontra IDs, atividades,
  conversas ou arquivos de B, mesmo que o identificador seja conhecido.
- Confirmar falha isolada: tornar o data plane de A indisponível e verificar
  que B e o control plane continuam respondendo.
- Guardar logs, status dos containers, smoke tests públicos e o identificador
  exato da imagem usada.

## 4. Migração da organização atual

Só iniciar após o canário aprovado:

1. colocar a organização em modo de manutenção curto e explícito;
2. exportar os dados operacionais filtrados por `organization_id`;
3. importar no data plane dedicado e executar contagens de reconciliação;
4. executar a promoção e os smoke tests autenticados;
5. liberar tráfego gradualmente;
6. observar erros, latência, filas e workers antes de migrar qualquer outra
   organização.

O export/import deve ser executado pelo migrador versionado, sempre começando
em modo de simulação:

```bash
SOURCE_DATABASE_URL='(origem)' DATA_PLANE_DATABASE_URL='(destino)' \
  pnpm tenancy:organization:plan --organization-id '(uuid)'
```

O plano descobre tabelas tenant-scoped pelo catálogo do PostgreSQL, inclui
dependentes por chave estrangeira e exibe contagens de origem/destino sem
escrever. Só depois de revisar o relatório é permitido aplicar:

```bash
SOURCE_DATABASE_URL='(origem)' DATA_PLANE_DATABASE_URL='(destino)' \
  pnpm tenancy:organization:plan --organization-id '(uuid)' \
  --apply --confirm-org '(uuid)'
```

O comando aborta e faz rollback da transação em qualquer erro; depois da
transação ele repete as contagens e falha se o destino não alcançou a origem.
O resultado JSON deve ser guardado como evidência do canário. URLs e segredos
não são impressos.

O control plane, proxy, Redis, WAHA e a imagem atual permanecem inalterados
até a validação pública do canário.

## 5. Rollback

O rollback tem dois níveis independentes:

- **Tenant:** alterar o registro para `degraded` ou remover o roteamento para o
  data plane e retornar ao caminho compartilhado somente enquanto a
  reconciliação confirmar que nenhuma escrita exclusiva ocorreu no dedicado.
- **Aplicação:** restaurar a imagem imutável anterior no Coolify/Traefik,
  mantendo a tag e o digest anotados no relatório do deploy.

Não executar `git reset`, apagar containers ou remover bancos como parte do
rollback. Primeiro preservar logs e evidências; qualquer destruição exige uma
aprovação separada e um alvo exato.

## 6. Critério de liberação

O rollout só é considerado concluído quando houver evidência registrada de:

- data plane `ready` e schema compatível;
- isolamento positivo e negativo;
- smoke tests públicos e autenticados;
- todos os containers saudáveis;
- backup/restauração exercitados;
- rollback testado em homologação;
- imagem versionada, digest e plano de retorno documentados.

Sem esses artefatos, a instalação produtiva continua na imagem estável atual.

