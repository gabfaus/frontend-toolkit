# FTK-02A — Skills externas

Status: implementada para revisão humana, sem staging ou commit.

## Versões resolvidas

| Skill | Ref | Objeto da ref | Commit resolvido | Versão declarada | Licença |
|---|---|---|---|---|---|
| Impeccable | `skill-v4.1.2` | `5e91b04d272cc551349867dd90409d068c703bf5` | `63b04e2530f5c7b41ea83c133daab24f34912456` | `4.1.2` | Apache-2.0 |
| img2threejs | `v1.5.1` | `dede5909be4e494b228c801a55dda47439143932` | `dede5909be4e494b228c801a55dda47439143932` | `1.5.1` | Apache-2.0 |

O tag do Impeccable é anotado: o SHA do objeto da tag difere do commit final. Ambos são registrados no lock. O tag do img2threejs aponta diretamente para o commit.

## Checkouts e descoberta

```text
external/impeccable/                         # checkout ignorado
external/img2threejs/                        # checkout ignorado
.agents/skills/impeccable/                   # adapter fisico FTK-owned rastreado
.agents/skills/img2threejs/                  # adapter fisico FTK-owned rastreado
```

A descrição histórica de symlink/junction não é operacional: a arquitetura atual usa adapters físicos FTK-owned rastreados, e `scripts/sync-external-skills.ps1` valida e rejeita reparse points.
Atualizacao R12: a descricao de junction acima e historica. A arquitetura atual exige adapters fisicos proprios do FTK; o sincronizador valida e rejeita reparse points e nao copia SKILL.md upstream para a raiz de discovery.


Esse mecanismo mantém uma fonte única para cada Skill. Nenhum arquivo upstream é copiado para `.agents/skills`.

### Nomes observados pelo Codex

`codex debug prompt-input` confirmou os locators repo-locais e os seguintes nomes:

- `img2threejs`;
- `impeccable:impeccable`.

O Impeccable é namespaced porque sua Skill vem da árvore `plugin/skills/impeccable` do upstream. Criar um wrapper ou copiar o `SKILL.md` apenas para remover o namespace criaria uma segunda fonte e foi rejeitado. A invocação explícita validada é `$impeccable:impeccable`.

## Impeccable sem hook

O instalador `npx impeccable install` não foi usado porque:

1. Node/npm/npx não estão disponíveis no `PATH`;
2. o fluxo normal pode instalar `.codex/hooks.json`;
3. hooks estão explicitamente fora da FTK-02A.

A Skill principal foi exposta diretamente a partir do checkout pinado. `plugin/skills/impeccable/SKILL.md`, suas referências e scripts estão acessíveis. Nenhum `.codex/hooks.json` ou configuração global foi criado.

Limitação: os scripts `.mjs` da Skill não podem ser executados até existir Node compatível. O `package.json` do checkout declara Node `>=22.18.0`; a versão do pacote CLI no mesmo commit é `3.6.1`, independente da versão da Skill `4.1.2`.

## img2threejs

O próprio checkout é a raiz da Skill e contém `SKILL.md`, `forge/`, `grimoire/`, `docs/`, `scripts/` e `integrations/`. A descoberta usa `.agents/skills`, apesar do exemplo legado do upstream com `~/.codex/skills`.

Os scripts principais requerem Python 3.10+ e, segundo `forge/requirements.txt`, usam apenas a biblioteca padrão. Não há Python instalado neste ambiente; por isso a estrutura é acessível, mas a execução dos gates Python permanece bloqueada.

## Runtimes observados

| Runtime | Resultado | Uso nesta etapa |
|---|---|---|
| Git | `2.49.0.windows.1`, `C:\Program Files\Git\cmd\git.exe` | checkouts, refs e validação |
| Node.js | ausente do `PATH` | bloqueia scripts/instalador do Impeccable |
| npm/npx | ausentes do `PATH` | instalador upstream não executado |
| Python | ausente; `py.exe` existe, mas não encontra instalação | bloqueia scripts do img2threejs |

Runtimes privados do Codex Desktop não são dependências do toolkit e não foram usados para integrar ou testar as Skills.

## Resultados dos testes

- Sincronizador em modo normal: passou e criou as duas junctions.
- Estado atual: os adapters sao diretorios fisicos FTK-owned; junctions nao fazem parte do preflight vigente.
- Sincronizador `-ValidateOnly`: passou para origem, SHA, worktree externo limpo, hash do `SKILL.md` e targets.
- Teste estrutural: passou para metadata, versões, referências/scripts, coexistência e ausência de `.codex/hooks.json`.
- Descoberta determinística com `codex debug prompt-input`: passou para `impeccable:impeccable` e `img2threejs`, ambos apontando para `.agents/skills/.../SKILL.md`.
- Carregamento read-only do Impeccable: retornou `4.1.2 reference/new-work.md`.
- Carregamento read-only do img2threejs: retornou `1.5.1 — forge/state.py`.
- Execução funcional dos scripts: não realizada; bloqueada pelos runtimes ausentes e fora do objetivo de integração estrutural desta máquina.

As execuções Codex read-only emitiram um aviso de teardown de MCP por programa ausente quando a configuração de usuário foi carregada. Os testes seguintes usaram `--ignore-user-config`; o aviso não altera a descoberta das Skills e nenhum MCP foi configurado pelo toolkit.

## Atualização controlada

1. Consultar tags e changelog sem alterar os checkouts.
2. Escolher uma nova tag estável.
3. Resolver objeto da ref e commit final.
4. Em checkout temporário, verificar licença, `SKILL.md`, versão, hashes e requisitos.
5. Atualizar um registro por vez em `external.lock.json`.
6. Recriar o checkout e as junctions com o script de sincronização.
7. Rodar `tests/test-skill-integration.ps1` e um teste de descoberta em nova sessão Codex.
8. Revisar o diff antes de qualquer staging.

Não atualizar checkouts existentes silenciosamente e não acompanhar `main`.

## Desenvolvimento versus plugin final

A documentação oficial de plugins descreve Skills empacotadas em `skills/`, mas nesta fase as dependências externas permanecem independentes e são descobertas repo-localmente por `.agents/skills`.

A FTK-05 deverá decidir a estratégia definitiva de distribuição sem presumir suporte nativo a dependências entre plugins. Copiar Skills, exigir plugins upstream ou gerar um pacote composto têm implicações distintas de atualização e licença que só devem ser decididas após os testes de empacotamento.
