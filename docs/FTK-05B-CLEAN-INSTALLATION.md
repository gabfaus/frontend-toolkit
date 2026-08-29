# FTK-05B — Clean Installation & Distribution Validation

Status: **READY FOR HUMAN REVIEW** em 2026-08-29. Nenhum plugin foi instalado no ambiente principal, publicado, staged ou commitado.

## Resultado

O marketplace repo-local e os comandos `codex plugin marketplace add`, `plugin add`, `plugin remove` e `plugin list` foram exercitados com Codex CLI 0.150.1 e `CODEX_HOME` efêmero. A fixture foi removida integralmente após cada ensaio.

### Pré-requisitos externos pinados

O plugin-fonte FTK-05A instalou e removeu corretamente em uma ação, mas o cache instalado continha somente `frontend-orchestrator`. Impeccable e img2threejs continuaram dependências separadas, pois o formato oficial não resolve dependências transitivas entre Skills/plugins. Essa estratégia preserva independência e evita duplicação, mas não atende a preferência de produto de uma instalação única nem garante máquina limpa/offline.

### Snapshots gerados

Duas árvores foram geradas diretamente dos SHAs em `integrations/external.lock.json` por `git archive`, sem rede e sem alteração dos checkouts. As árvores completas foram idênticas, com SHA-256 agregado observado `95b00da184ce918ac8ff2bab7ffc6df913f08359edc159545bad1b0ec2b975ab`.

- Impeccable inclui somente `plugin/skills/impeccable` e uma cópia íntegra de `LICENSE` em `third_party/impeccable/LICENSE`.
- img2threejs inclui a árvore do commit sob `skills/img2threejs`, inclusive `SKILL.md`, scripts, referências e `LICENSE`.
- Os hashes das licenças foram comparados com o lock.
- Snapshots são artefatos gerados efêmeros; não são fonte de verdade e não são persistidos no repositório na FTK-05B.

Uma única instalação expôs no cache do Codex:

- `frontend-orchestrator`;
- `impeccable`;
- `img2threejs`;
- MCP `shadcn`;
- MCP `21st`.

Atualização pelo helper oficial de cachebuster, remoção e reinstalação passaram sem cache residual. `API_KEY_21ST` permaneceu apenas em `bearer_token_env_var`; nenhum MCP foi iniciado e nenhuma operação 21st ocorreu.

O helper instalado emitiu `+codex.YYYYMMDDHHMMSS`, enquanto a referência textual local descreve `+codex.local-YYYYMMDD-HHMMSS`; o teste segue o helper executável pinado e registra essa divergência como risco de compatibilidade documental.

## Comparação final

| Critério | Pré-requisitos externos | Snapshots gerados |
|---|---|---|
| Instalação única | Não | Sim |
| Portabilidade/máquina limpa | Depende de instalação adicional | Um pacote contém as três Skills |
| Offline | Depende de checkouts/cache prévios | Skills funcionam a partir do pacote; Shadcn ainda depende do runtime/cache npm e 21st permanece remoto |
| Atualização | Atualizar prerequisitos separadamente | Atualizar locks e regenerar; nenhuma edição manual |
| Manutenção | Menor no pacote, maior operacionalmente | Gerador simples, revisão de diff/hash por release |
| Licença/atribuição | Mantidas nos upstreams | LICENSE preservada e THIRD_PARTY_NOTICES obrigatório |
| Dependências externas | Git/checkouts adicionais | Runtimes e MCP remoto; sem checkout no uso final |
| Divergência | Versões instaladas podem divergir | Baixa se sempre regenerado dos SHAs e nunca editado |

## Arquitetura recomendada

Distribuir um único plugin contendo snapshots gerados de Impeccable e img2threejs. Os checkouts e `integrations/external.lock.json` continuam fontes de verdade; `scripts/build-plugin-snapshot.ps1` é o único mecanismo de materialização. O artefato deve ser construído fora da árvore versionada, validado, instalado e descartado. Nenhuma alteração manual dentro dos snapshots é permitida.

## Evidência e limites

`tests/test-plugin-distribution.ps1` cobre geração dupla, hash, licenças, instalação, discovery no cache, política básica de routing, atualização por cachebuster, remoção, reinstalação, teardown e integridade de config/PATH/checkouts.

O routing comportamental não foi reexecutado com modelo durante a instalação: a Skill empacotada é byte-equivalente à FTK-04B já aprovada, e a fixture confirmou o mesmo `routing-policy.json`. Os MCPs foram descobertos pelo pacote, mas não inicializados, evitando rede, quota e qualquer risco 21st.

## Bloqueios para fechar FTK-05

1. `AGENTS.md` ainda proíbe copiar dependências externas. A evidência agora justifica uma exceção estreita para artefatos gerados, mas essa mudança de governança exige aprovação humana específica.
2. A licença do código próprio continua `UNLICENSED`, o que bloqueia distribuição/publicação.
3. O validador canônico `plugin-creator` ainda requer PyYAML indisponível no ambiente; a dependência não foi instalada.
4. Um smoke comportamental em nova sessão instalada permanece pendente de um fluxo de autenticação isolado que não copie secrets do perfil principal.
