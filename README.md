# Frontend Toolkit

Frontend Toolkit é um plugin open source para Codex e Claude Code que reúne workflows especializados de frontend, UX, componentes e reconstrução 3D sob um roteador único e conservador.

O projeto está licenciado sob Apache-2.0. A remediação de segurança G7-S e a remediação de canonicalização estão CLOSED/complete. O Frontend Toolkit `1.3.0` é a candidata corrente, classificada como MINOR_VERSION / BACKWARD_COMPATIBLE_FEATURES, e está preparada para fechamento Git controlado. A tag futura `v1.3.0` ainda não foi criada. A tag local anotada `v1.2.0` aponta para `6ddc02f4ee806b07d39b055054a9dd76f116e219`; isso comprova existência local, não publicação remota. Não há evidência neste gate de GitHub Release ou publicação de marketplace para `1.3.0`. A tag histórica `v1.0.0` permanece imutável.

## Importação pelo marketplace GitHub do Codex

Após a publicação do repositório, um administrador pode importar o marketplace Codex em **Workspace settings > Plugins > Add > Import marketplace**:

```text
Source: https://github.com/gabfaus/frontend-toolkit
Path:   (vazio; o manifest está em .agents/plugins/marketplace.json)
```

O manifest usa o schema oficial `source: "local"` com o caminho relativo `./plugin/frontend-toolkit`. Para uma release reproduzível, selecione a tag ou o commit exato; sincronização diária e **Sync now** são controladas pelo workspace. A importação não concede autenticação, permissões de apps nem política de instalação.

## ChatGPT Web e Desktop

A candidata `1.3.0` é **Desktop only** e **NOT SUPPORTED** no ChatGPT Web. O plugin declara `.mcp.json`, incluindo Shadcn local e 21st remoto; plugins importados com MCP recebem a restrição Desktop only. Um profile Web-safe exigirá contrato oficial e trabalho futuro separado.


## O que o plugin oferece

```text
Frontend Toolkit
├── frontend-orchestrator   roteamento, precedência e gates de segurança
├── Impeccable              design, UX, crítica e refinamento visual
├── img2threejs             imagem para modelo procedural Three.js
├── Shadcn MCP              consulta ao registry oficial de componentes
├── 21st MCP                inspiração e descoberta remota
└── Claude Code adapter     empacotamento e lifecycle isolados do host Claude
```

- **frontend-orchestrator:** usa `QUALITY_FIRST` como default, seleciona a capability principal e adiciona somente complementos com ganho material distinto, preservando a intenção explícita do usuário.
- **Impeccable:** cobre composição, hierarquia, acessibilidade, responsividade e qualidade de interface.
- **img2threejs:** transforma referências visuais em modelos Three.js construídos em código. G7-SR2D medeia state, GLB, codec, TypeScript e Vite com runtimes/argv/ambiente controlados pelo FTK; os defects preservados no snapshot v1.5.1 não são executados diretamente.
- **Shadcn MCP:** consulta read-only ao registry oficial usando `shadcn@4.19.0`.
- **21st MCP:** no Codex, serviço remoto em `https://21st.dev/api/mcp`; no Claude Code, somente uma facade MCP local FTK faz a ponte search-only. A autenticação usa apenas a variável externa `API_KEY_21ST`.
- **Claude Code:** adapter inicial para Windows x64, com manifesto, dois MCPs locais, launchers governados e runtime privado separado do artefato Codex.

Impeccable e img2threejs permanecem projetos upstream independentes. A descoberta usa adapters próprios do FTK; nenhum `SKILL.md` upstream fica em `.agents/skills` ou em `skills/` do artefato. O build gera snapshots imutáveis e byte-verificados dos SHAs pinados somente sob `third_party/upstreams/`, com provenance separada. O build de release continua extraindo o código próprio de `HEAD` por allowlist exata; o modo `-DevelopmentWorkingTree` existe apenas para validar gates ainda não commitados e mantém as mesmas verificações de composição, reparse points e paths sensíveis.

Na candidata `1.3.0`, as fundações entregues permanecem explicitamente limitadas:

- design-motion Phase 1: `taste`, `review-animations` e `improve-animations` são `REQUEST_ONLY`; `animate` é `REGISTERED_NO_HANDLER`;
- Browser QA e Accessibility são `REQUEST_ONLY`; a evidência dedicada segura em navegador real permanece `PENDING_ENVIRONMENT`;
- img2threejs procedural Phase 1 é `REQUEST_ONLY`; Phase 2 é `REGISTERED_NO_HANDLER` e preview é `UNAVAILABLE`;
- o pipeline GLB existente de img2threejs é preservado.

## Modelo de routing e execução

`QUALITY_FIRST` é o default. `FIDELITY_FIRST` só é ativado por intenção semântica explícita. `CORE` não significa `DEFAULT_LOADED`; selection não é authorization; availability não é routing, operation ou effect. As superfícies usam os estados `EXECUTABLE`, `REQUEST_ONLY`, `REGISTERED_NO_HANDLER` e `UNAVAILABLE`, sem chamar request-only de executável.

G7-SR3I integra o Impeccable por uma cadeia fail-closed de autoridade, operação tipada, efeitos independentes e handler fixo. Contexto local passa por extractor e mediator FTK-owned; conteúdo upstream/projeto nunca concede autoridade. Como o plugin atual não recebe evidência host não-forjável, rede, telemetry, paid generation, live efetivo e mutações sensíveis permanecem discoverable, porém retornam `AUTHORIZATION_REQUIRED`. Veja [G7-SR3I](docs/G7-SR3I-IMPECCABLE-INTEGRATED-BOUNDARY.md).

## Política de custo e mutação do 21st

Somente `21st/search` é autorizado automaticamente. No artefato Claude, a facade local expõe apenas `search` e falha fechado para ferramentas desconhecidas. Geração, iteração, consumo de créditos ou quota, recuperação/cópia/instalação de código, publicação, edição, exclusão, bookmarks, listas, conta/perfil, qualquer mutation e qualquer tool nova ou de efeito incerto exigem autorização explícita.

O pacote não inclui Magic MCP, Jpisnice, plugin oficial do 21st, Skills oficiais do 21st ou hooks. Quando suportado pelo ambiente, recomenda-se também limitar tecnicamente o MCP 21st a `search`; essa configuração do consumidor complementa, mas não substitui, a política semântica do orchestrator. O 21st é opcional para todas as demais capacidades.

## Requisitos

- Windows x64 e PowerShell 5.1 ou posterior para os scripts versionados;
- Git no `PATH` para construir a partir do source;
- Codex CLI `0.150.1` (minimum validated);
- Codex CLI `0.153.4` (current validated);
- Claude Code `2.1.261` (current validated; minimum validated: not yet established; Windows x64);
- Node.js `24.20.0` (validado; Shadcn requer Node `>=20.18.1`);
- CPython `3.14.7` (validado; img2threejs requer Python `>=3.10`);
- acesso de rede para reconstruir upstreams, iniciar Shadcn e acessar o 21st;
- `API_KEY_21ST` opcional e externa, necessária apenas para uso autenticado do 21st.

As versões e hashes validados estão em `integrations/toolchain.lock.json`, `integrations/external.lock.json` e `integrations/mcp.lock.json`.

## Instalação a partir do source

A instalação a partir do source é destinada à reprodução controlada por mantenedores. Codex e Claude Code usam artefatos separados, gerados do mesmo source commit. A distribuição pública futura deverá usar os assets oficiais da GitHub Release `v1.3.0`, após validar os SHA-256 publicados nas release notes ou manifest externo.

Depois de clonar este repositório:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-external-skills.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-candidate.ps1 -Destination .\release-artifacts\v1.3.0-codex
codex plugin marketplace add "$PWD\release-artifacts\v1.3.0-codex"
codex plugin add frontend-toolkit@frontend-toolkit-local
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-claude-release-candidate.ps1 -Destination .\release-artifacts\v1.3.0-claude
```

O primeiro comando baixa somente os refs pinados para `external/`. O segundo cria a marketplace Codex com o plugin completo e os snapshots; o último cria o artefato Claude com a facade local e seu runtime privado. `release-artifacts/` é ignorado pelo Git. O source continua sem snapshots nem dependências materializadas.

Veja [Instalação](docs/INSTALLATION.md) para validação, configuração de menor privilégio, instalação por artefato e autenticação isolada.

## Configuração do 21st

Cada usuário autentica sua própria conta Codex e fornece sua própria `API_KEY_21ST`, externamente pelo ambiente ou por um gerenciador de secrets. Nenhuma chave do mantenedor acompanha o plugin. Nunca grave o valor em `.mcp.json`, `config.toml`, scripts, logs ou no repositório. A ausência da variável não impede discovery das três Skills nem uso do Shadcn; apenas deixa o smoke autenticado do 21st indisponível.

No Claude Code, o plugin é carregado por `--plugin-dir` ou pelo lifecycle de marketplace/cache do próprio Claude. O `.mcp.json` Claude configura somente os launchers locais FTK; ele nunca configura diretamente o endpoint remoto do 21st. A instalação e a descoberta não exigem login Anthropic nem chamada de modelo.

Para conferir somente a presença da variável, sem revelar seu conteúdo:

```powershell
Test-Path Env:API_KEY_21ST
```

## Uso

Descreva a tarefa normalmente; não é necessário nomear uma ferramenta. Exemplos:

- `Qual componente oficial você recomenda para abrir um formulário em um modal?`
- `Revise a hierarquia visual e a acessibilidade desta tela.`
- `Quero transformar esta imagem em um asset para usar com Three.js.`
- `Procure inspiração para componentes de dashboard moderno.`

Se uma ação do 21st puder consumir créditos, quota ou modificar estado, o plugin deve parar e pedir autorização antes da chamada. Skills distribuídas contêm código local executável; consulte [Security model](docs/SECURITY-MODEL.md) antes de instalar ou executar.

## Atualização e remoção

Atualizações seguem SemVer e exigem regenerar o candidato a partir dos locks revisados. Durante desenvolvimento local, o cachebuster oficial mantém a versão base e acrescenta `+codex.YYYYMMDDHHMMSS`; ele não substitui a versão pública.

```powershell
codex plugin remove frontend-toolkit@frontend-toolkit-local --json
codex plugin marketplace remove frontend-toolkit-local
```

Veja [Atualização](docs/UPDATING.md) para upgrade, rollback e mudanças de upstream.

## Troubleshooting essencial

- **Plugin não aparece:** confirme `codex plugin list`, a marketplace `frontend-toolkit-local` e abra uma nova sessão após instalar/atualizar.
- **Shadcn não inicia:** confirme `node --version`, `npx --version`, rede e o pin `shadcn@4.19.0`.
- **21st não autentica:** confirme apenas a presença de `API_KEY_21ST`; não imprima o valor.
- **Build falha em upstream:** remova somente o checkout externo defeituoso, execute novamente a sincronização e confira SHA/licença contra o lock.
- **Validator pede PyYAML:** `PyYAML==6.0.3` é dependência temporária do validator oficial, não do produto; use `tests/test-plugin-official-validation.ps1 -Execute`.

## Segurança, contribuição e licenças

- [Política de segurança](SECURITY.md)
- [Guia de contribuição](CONTRIBUTING.md)
- [Versionamento](docs/VERSIONING.md)
- [Checklist de release](docs/RELEASE-CHECKLIST.md)
- [Changelog](CHANGELOG.md)
- [Apache License 2.0](LICENSE)
- [Atribuições de terceiros](THIRD_PARTY_NOTICES.md)

Código próprio e `frontend-orchestrator` usam Apache-2.0. Impeccable e img2threejs preservam Apache-2.0 upstream; Shadcn é MIT e resolvido em runtime; 21st é serviço remoto e nenhum código seu é incorporado.

## Status

FTK-06 permanece **CLOSED** como marco histórico de 2026-08-29. G7-S está **CLOSED/complete**, com zero findings HIGH/CRITICAL remanescentes, e a remediação de canonicalização está **CLOSED**. O Frontend Toolkit `1.3.0` é a candidata corrente multi-host; os artefatos Codex e Claude são separados, a tag `v1.3.0` ainda não foi criada e nenhuma GitHub Release ou marketplace foi publicada para esta candidata. A tag local anotada `v1.2.0` permanece distinta de publicação remota.
