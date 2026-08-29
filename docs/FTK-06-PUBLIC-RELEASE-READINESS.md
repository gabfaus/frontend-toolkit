# FTK-06 — Public Release Readiness

Status: **CLOSED** após revisão humana em 2026-08-29. Nenhuma tag, release, publicação ou push foi realizado.

## Escopo

FTK-06 prepara o source Apache-2.0 e um candidato local `v1.0.0` para leitura e instalação por terceiros. Routing, capabilities, pins, runtimes e política 21st permanecem inalterados.

## Estrutura pública

- `README.md`: visão geral, requisitos, instalação, uso, custo, lifecycle e troubleshooting;
- `SECURITY.md`: reporte privado e modelo de segurança;
- `CONTRIBUTING.md`: regras para contribuição e validação;
- `CHANGELOG.md`: primeira versão pública planejada;
- `docs/INSTALLATION.md` e `docs/UPDATING.md`: procedimentos reproduzíveis;
- `docs/VERSIONING.md`: SemVer e impacto das dependências;
- `docs/RELEASE-CHECKLIST.md`: gates versionáveis;
- `scripts/build-release-candidate.ps1`: marketplace local e manifesto determinístico;
- `integrations/release.lock.json`: versão/hash/estado de publicação;
- `tests/test-public-release.ps1`: contratos públicos, privacidade e determinismo.

`CODE_OF_CONDUCT.md` não foi criado nesta primeira etapa: segurança e contribuição já definem os canais necessários, e uma política comunitária deve ser adotada quando houver uma comunidade/canal público real, sem inventar contato ou enforcement inexistente.

## Estratégia de distribuição

O source continua sem snapshots. Builds e releases materializam Impeccable e img2threejs exclusivamente dos SHAs pinados, sem edição manual, preservando LICENSE/NOTICE/proveniência. Essa separação reduz divergência e evita transformar cópias em fonte de verdade, enquanto o artefato continua instalável em uma ação e utilizável offline para as Skills já empacotadas.

O candidato inclui uma marketplace `frontend-toolkit-local`, o plugin completo e `RELEASE_MANIFEST.json`. O manifesto lista cada arquivo do plugin e seu SHA-256; o hash agregado é calculado sobre pares ordenados `path|sha256`, sem timestamp.

## Auditoria pública inicial

- paths absolutos de perfis Windows e referências ao nome de usuário: zero;
- e-mails pessoais: zero;
- secrets/chaves atribuídas: zero;
- arquivos ignorados já versionados: zero;
- snapshots externos no plugin source: zero;
- metadata pública: nome, descrição, versão `1.0.0`, Apache-2.0 e capacidades compreensíveis por terceiros.

Referências a `auth.json` em documentação/testes são proibições e verificações de isolamento, nunca conteúdo de credencial. O nome `Gabriel` permanece apenas como autoria pública deliberada do plugin; nenhum e-mail, endereço ou identificador privado foi adicionado.

## Candidato local

- versão: `1.0.0`;
- hash esperado da árvore do plugin: `1cdfb162b5b0924092613b5ccf9f484ae56b46ca8e2a9d13a1d33579b23f4924`;
- arquivos na árvore: 494;
- snapshots: somente no artefato;
- publicação/tag/release: não criadas.

## Clean-copy e candidato

Uma cópia em `%TEMP%` recebeu somente os 76 arquivos rastreados ou novos intencionais; `.git`, `external/`, junctions, runtimes, caches, profiles e credenciais não foram copiados. A partir dela:

- Impeccable e img2threejs foram clonados novamente pelos refs registrados e validados nos SHAs pinados;
- duas gerações independentes produziram 494 arquivos e hash `1cdfb162b5b0924092613b5ccf9f484ae56b46ca8e2a9d13a1d33579b23f4924`;
- a marketplace instalou o plugin em uma ação e descobriu três Skills e dois MCPs;
- remoção, reinstalação e cachebuster passaram sem resíduos de cache da instalação;
- Shadcn executou search/view read-only em fixture sintética;
- a credencial 21st externa estava disponível e exatamente uma `search` retornou resultados; zero tool paga, mutável ou copy/install foi chamada.

O clean-copy revelou e corrigiu dois problemas de harness, sem mudar arquitetura: warnings do `git clone` em stderr eram tratados como exceção pelo PowerShell, e o manifesto de release ordenava `OrderedDictionary` como se `path` fosse propriedade. O sincronizador agora decide pelo exit code nativo e o builder usa `PSCustomObject` para ordenação lexicográfica real.

## Instalação autenticada isolada

Foi criado um `CODEX_HOME` novo em `%TEMP%`, sem copiar config, auth, tokens, profiles, memories ou caches. A autenticação usou o fluxo oficial `codex login --device-auth` com `cli_auth_credentials_store = "file"`; apenas presença/status foram verificados.

Resultados do plugin instalado:

| Gate | Resultado |
|---|---|
| Discovery | `frontend-orchestrator`, `impeccable`, `img2threejs`; MCPs `shadcn`, `21st` |
| Orchestrator | PASS; modal/formulário roteou para Shadcn |
| Shadcn | PASS; `search_items_in_registries`, read-only |
| 21st | PASS; somente `search` |
| img2threejs | PASS; escrita confinada a `.img2threejs/` da fixture |
| Cost gate | PASS; geração bloqueada sem autorização, zero MCP |
| Update | PASS; `1.0.0+codex.20260829220549` |
| Remove/reinstall | PASS; três Skills e dois MCPs restaurados |
| Nova sessão | PASS; pós-update roteou para Shadcn sem MCP |

Operações 21st pagas, mutáveis ou copy/install: zero.

## Teardown e integridade final

O logout oficial removeu a autenticação isolada; plugin e marketplace foram removidos antes das fixtures. A exclusão final confirmou ausência de `CODEX_HOME`, workspace, clean-copy, candidato, snapshots, junctions, caches e upstreams temporários FTK-06.

- config Codex principal: sem referência FTK e inalterada pelos harnesses;
- User PATH e Machine PATH: inalterados e sem referência às fixtures;
- checkouts Impeccable/img2threejs do repositório principal: limpos nos SHAs pinados;
- secrets, paths pessoais e arquivos ignorados versionados: zero;
- snapshots no plugin source: zero;
- tag `v1.0.0`, release, publicação e push: não realizados.

## Conclusão

Os critérios técnicos da FTK-06 foram atendidos e a revisão humana aprovou seu fechamento. **Frontend Toolkit V1 — PUBLIC RELEASE READY.** O source continua sem snapshots e o candidato não foi publicado. A criação de repositório público, URL definitiva, tag `v1.0.0`, release e publicação continuam gates humanos/operacionais separados.
