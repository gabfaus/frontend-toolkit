# FTK-09L - Release Freeze v1.2.0

Status: FROZEN RC. Esta candidata esta preparada para auditoria de publicacao no FTK-09M. Este gate nao cria tag, GitHub Release, marketplace publico ou push.

## Baseline e locks

- Branch: `ftk-09l-release-freeze`
- Baseline recebido: `c14a5ab40e65e83d6ffe881685eee44bfb7eca3e`
- Versao candidata: `1.2.0`
- Lock final: `locked-current-candidate`
- `persistentLocksMatchCandidate`: `true`
- `lockUpdateRequired`: `false`
- Fonte persistente de hashes: committed HEAD; `DevelopmentWorkingTree` e apenas diagnostico.
- Identidades de `integrations/release.lock.json` sao FROZEN RC IDENTITIES, nao published release identities.
- FROZEN RC PluginTreeSha256: fdc314fb6f5cfdae63d34de9bc7576e8866b6696e277e541ff3728a950850b5f
- FROZEN RC ArtifactTreeSha256: 4e863796dd6ca8732752c9ae10f98f8f9817dc9c0fa23941ff72c3adf052d8e5
- FROZEN RC ZIP SHA256: c71cfdbc6158907ed356e2341f4cabf9a76c4986b6e41232a5fe2607e4da4178
- Claude frozen RC ZIP SHA256: 676b833a9bd3fc79e01bb8c35a253379b5add4b4f13545a9763bd0fc65991089
- O registro de v1.1 esta em `integrations/release-history.json` e nao deve ser sobrescrito pelos locks atuais.

## Orchestrator coverage

A matriz [orchestrator-coverage.v1.2.json](../integrations/orchestrator-coverage.v1.2.json) e a evidência machine-readable. Ela referencia a policy do `frontend-orchestrator`, cobre PLAN/EXECUTE/VERIFY, disponibilidade, efeitos, autorizacao, hosts, rota e fail-closed para todas as 18 capabilities. Tambem registra os caminhos auxiliares 21st nao-search e `@playwright/test`.

Resultado esperado: `NO ORPHAN CAPABILITIES`.

Impeccable continua a autoridade primaria de design/UX. Shadcn continua preferencial para componentes oficiais; 21st e apenas inspiracao/search por padrao. Figma, acessibilidade, browser QA, Context7 e Storybook permanecem seletivos/condicionais. Nenhuma capability e carregada apenas porque esta disponivel.

## Host surfaces

Codex descobre 6/6 Skills esperadas: `figma-design-to-code`, `frontend-accessibility`, `frontend-orchestrator`, `img2threejs`, `impeccable` e `playwright-cli`. O payload do plugin Codex contem as quatro Skills FTK-owned; accessibility e Playwright sao Skills do host/projeto e nao sao copiadas artificialmente para Claude.

Claude descobre 4/4: `figma-design-to-code`, `frontend-orchestrator`, `img2threejs` e `impeccable`. O adapter usa `claude/mcp.json` e as facades locais governadas; nao recebe accessibility/playwright por simetria artificial.

## ChatGPT Web readiness

O artefato atual e Desktop/local-runtime oriented:

- o manifesto Codex usa paths relativos para `skills/` e `.mcp.json`;
- o Shadcn depende de um processo local `npx`/Node;
- o adapter Claude depende de PowerShell, Node, runtime privado materializado e facade local;
- img2threejs depende de runner e estado local confinado;
- o 21st usa endpoint remoto, mas a credencial continua somente externa e a policy search-only permanece local;
- Figma, Playwright, Context7 e Storybook dependem de transportes/integrações do host e do projeto.

A parte portável hoje e o texto de policy/documentacao e a selecao conceitual minima do orchestrator quando o host Web oferece um mecanismo de Skills compatível. O artifact completo nao deve ser importado no Web como se essas capacidades fossem executáveis.

O `.mcp.json` atual nao e um WEB-SAFE profile: ele combina um comando local para Shadcn e uma entrada remota 21st com interpolacao de ambiente. Nao foi criado um schema de marketplace Web inventado neste gate. O 09M deve confirmar o contrato do host e, se suportado, derivar do mesmo repo um profile Web-safe com apenas capabilities realmente executaveis, mantendo o mesmo `frontend-orchestrator` e sem fork.

## Codex installation readiness

O plugin manifest `plugin/frontend-toolkit/.codex-plugin/plugin.json` usa paths relativos e nao injeta config global. A reproducao local e suportada pelo builder `scripts/build-release-candidate.ps1`, que gera uma marketplace local com `source: local` e o plugin separado.

Import por marketplace GitHub nao e afirmado como suportado nesta candidata: o schema exato e o lifecycle de import remoto do Codex precisam de confirmacao no 09M. A superficie Claude possui seu proprio `.claude-plugin/marketplace.json` e asset separado; ela nao deve ser usada como schema Codex.

Verificacoes locais sem servico externo real:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-orchestrator-coverage.ps1
node .\tests\test-context7-facade.mjs
```

Para validar discovery em um ambiente Codex isolado, use a CLI oficial e `CODEX_HOME` temporario; nunca copie auth, cookies ou config pessoal.

## Playwright decision

`@playwright/cli@0.1.19` permanece `ACCEPT_WITH_RESTRICTIONS` na integracao de source. A aceitacao da release continua `PENDING_FINAL_RELEASE_REVIEW`. A versao nao foi trocada e o runtime `@playwright/test` continua apenas suporte project-owned, sem instalacao automatica.

## Publication boundary

Apos este freeze ainda faltam a auditoria humana FTK-09M, confirmacao do profile Web/Codex marketplace remoto, revisao final do Playwright, validacao dos assets publicados e eventual decisao de tag/release/publicacao. Nenhuma dessas acoes e implicada por este documento.