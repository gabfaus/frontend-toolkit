# Instalação pública

## Escolha do formato

A release pública v1.3.0 entrega artefatos separados para Codex e Claude Code. O repositório-fonte não versiona snapshots externos; os builders os geram dos SHAs pinados e criam artefatos instaláveis a partir do mesmo source commit.

O artefato contém:

```text
frontend-toolkit-v1.3.0-codex/
├── .agents/plugins/marketplace.json
├── plugins/frontend-toolkit/
│   ├── .codex-plugin/plugin.json
│   ├── .mcp.json
│   ├── skills/frontend-orchestrator/
│   ├── skills/impeccable/
│   ├── skills/img2threejs/
│   ├── third_party/
│   └── SNAPSHOT_PROVENANCE.json
└── RELEASE_MANIFEST.json
```

O artefato Claude possui `.claude-plugin/plugin.json`, `.mcp.json`, as mesmas três Skills e os mesmos arquivos comuns, além de `security/claude/` com os dois launchers, a facade 21st search-only e o runtime MCP privado. O artefato Claude é separado do artefato Codex.

## Artefatos oficiais da release v1.3.0

Use a [GitHub Release v1.3.0](https://github.com/gabfaus/frontend-toolkit/releases/tag/v1.3.0) como fonte oficial dos ZIPs e valide os hashes localmente:

- Codex: `frontend-toolkit-codex-v1.3.0.zip`
  SHA-256: `d338790a7c52941048927c6f8bc1cb973a8a797cf49ac2b0e748e15b36c24f73`
- Claude: `frontend-toolkit-claude-v1.3.0.zip`
  SHA-256: `7bb4ab0cf59efa3f02f8e5d9c137a2f7703429f2b829ae69ed928d2df3a6c19f`

Não há assets `.sha256` separados.

## Requisitos

Para instalar um artefato pronto: Codex CLI `0.150.1` (minimum validated), Node.js compatível com Shadcn e Python compatível com img2threejs. O Codex CLI `0.153.4` é a versão current validated. Para construir do source também são necessários Git, PowerShell e acesso aos upstreams registrados.

Versões validadas:

- Codex CLI `0.150.1`;
- Codex CLI `0.153.4`;
- Claude Code `2.1.261` (current validated; minimum validated: not yet established; Windows x64);
- Node.js `24.20.0`;
- CPython `3.14.7`;
- Windows x64 e PowerShell 5.1+.

## Construir do source

Na raiz de um clone limpo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-external-skills.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-candidate.ps1 -Destination .\release-artifacts\v1.3.0-codex
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-claude-release-candidate.ps1 -Destination .\release-artifacts\v1.3.0-claude
```

A sincronização valida origem, ref, commit, árvore limpa, `SKILL.md` e licenças. O builder falha se o destino existir, sobrepuser o source ou se qualquer checkout divergir do lock.

## Instalar em uma ação

```powershell
codex plugin marketplace add "$PWD\release-artifacts\v1.3.0-codex"
codex plugin add frontend-toolkit@frontend-toolkit-local
```

Abra uma nova sessão do Codex depois da instalação. O plugin deve expor exatamente:

- Skills: `frontend-orchestrator`, `impeccable`, `img2threejs`;
- MCPs: `shadcn`, `21st`.

## Configurar autenticação e menor privilégio

Cada usuário usa sua própria conta Codex pelo fluxo normal de autenticação ChatGPT. Em testes ou automação, use um `CODEX_HOME` isolado e autentique com o fluxo oficial; nunca copie `auth.json` ou tokens.

`API_KEY_21ST` é opcional, pertence ao próprio usuário e deve vir do ambiente ou de um gerenciador de secrets. Nenhuma chave do mantenedor é distribuída. Não grave o valor em arquivos. Sem a variável, Skills e Shadcn continuam disponíveis; o 21st não é requisito para as demais capacidades.

## Efeitos de instalação e execução

Adicionar a marketplace e o plugin materializa arquivos e registra as três Skills e os dois MCPs. A instalação, por si só, não deve chamar tool paga, ler secret, enviar arquivo, alterar projeto ou ativar hook.

Usar uma Skill pode executar código local, iniciar subprocessos, ler ou escrever no workspace e acessar rede conforme o fluxo escolhido. Iniciar o Shadcn via `npx` pode baixar e executar o pacote exato pinado se ele não estiver em cache. Usar um MCP pode iniciar seu processo e comunicação de rede. Comandos retornados por registry ou MCP são dados: revise-os antes de executar.

G7-S está **CLOSED**, com zero findings HIGH/CRITICAL remanescentes, e a remediação de canonicalização está **CLOSED**. A release pública `1.3.0` está publicada na tag anotada imutável `v1.3.0`, com GitHub Release e os dois assets oficiais acima. A tag local anotada `v1.2.0` é histórica e não representa a distribuição atual. Para uso por terceiros, baixe os assets da GitHub Release `v1.3.0` e valide seus SHA-256.

Quando a versão do Codex suportar políticas MCP plugin-scoped, aplique no `config.toml` do consumidor:

```toml
[plugins."frontend-toolkit@frontend-toolkit-local".mcp_servers.shadcn]
enabled = true
enabled_tools = ["search_items_in_registries"]

[plugins."frontend-toolkit@frontend-toolkit-local".mcp_servers."21st"]
enabled = true
enabled_tools = ["search"]
```

Essa barreira técnica é configuração do usuário e não pode ser imposta pelo manifesto distribuído. O orchestrator continua responsável pelo gate semântico.

## Verificar a instalação

```powershell
codex plugin list
```

Em uma nova sessão, use os prompts de smoke documentados em `docs/RELEASE-CHECKLIST.md`. Não conceda autorização ao prompt de geração do cost gate.

## Instalar via marketplace público Claude Code

Adicione o marketplace público e instale o plugin Claude Code:

~~~powershell
claude plugin marketplace add gabfaus/frontend-toolkit
claude plugin install frontend-toolkit@frontend-toolkit
~~~

O marketplace Claude normal consome o manifesto live do repositório, cujo `.claude-plugin/marketplace.json` no estado ativo de `main` aponta para o asset oficial Claude `v1.3.0`. A tag imutável `v1.3.0` foi criada antes deste fechamento de metadata pós-release; portanto, não use o `.claude-plugin/marketplace.json` da tag como catálogo live. Para fixar o payload da release, use diretamente `frontend-toolkit-claude-v1.3.0.zip` e valide o SHA-256 `7bb4ab0cf59efa3f02f8e5d9c137a2f7703429f2b829ae69ed928d2df3a6c19f`.

## Importar pelo marketplace GitHub do Codex

O repositório contém o marketplace Codex em `.agents/plugins/marketplace.json`. Importe em **Workspace settings > Plugins > Add > Import marketplace**:

```text
Source: https://github.com/gabfaus/frontend-toolkit
Path:   (vazio; o manifest está na raiz do repositório)
```

O entry usa o schema oficial `source: "local"` e o caminho relativo `./plugin/frontend-toolkit`. Para fixar uma release, informe a tag ou o commit exato. O import não concede acesso a apps, autenticação ou política de instalação; sincronização diária e **Sync now** são controladas pelo workspace.

## Codex, Claude Code e ChatGPT Web

O Codex usa o manifest `.codex-plugin/plugin.json`, a marketplace local gerada pelo builder e as seis Skills descobertas no host: `frontend-orchestrator`, `figma-design-to-code`, `impeccable`, `img2threejs`, `frontend-accessibility` e `playwright-cli`. O payload FTK distribui as quatro Skills FTK-owned; as duas ultimas sao condicionais do host/projeto.

O Claude usa `.claude-plugin/plugin.json`, `claude/mcp.json`, as facades locais e exatamente quatro Skills: `frontend-orchestrator`, `figma-design-to-code`, `impeccable` e `img2threejs`. Accessibility e Playwright nao sao adicionados ao Claude apenas para simetria.

O artifact atual e `Desktop only` e `NOT SUPPORTED` no ChatGPT Web. Ele depende de `.mcp.json`, paths locais, PowerShell, Node, runners locais e, no caso do 21st, interpolacao de ambiente para credencial externa. Uma distribuicao Web-safe exige contrato oficialmente suportado e fica como follow-up.

O marketplace GitHub Codex usa `.agents/plugins/marketplace.json` com `source: "local"` e caminho relativo `./plugin/frontend-toolkit`; `.claude-plugin/marketplace.json` continua sendo a superficie Claude.
## Current 1.3.0 release disposition

**CHATGPT WEB — release 1.3.0:** `NOT SUPPORTED`; o artifact é Desktop only porque declara `.mcp.json`, incluindo Shadcn local e 21st remoto. Uma distribuição Web-safe exigirá contrato oficialmente suportado e fica como follow-up.

**PLAYWRIGHT FINAL RELEASE ACCEPTANCE:** `ACCEPT_WITH_RESTRICTIONS`
- exact version: `@playwright/cli@0.1.19`.
- integrity: CLI `sha512-eGXIsYa5D+dC6wHGf+9uEislhPGip1djK+yiNAD7BVsXN3WzzR1J4ClFAhYhyu7wSEFqhcPrqXAYeBJF1dKJ7A==`; effective `playwright` and `playwright-core` integrities are recorded in `integrations/browser-qa.lock.json`.
- provenance limitation: npm metadata omits trusted publisher, `gitHead` and Sigstore/SLSA attestations; tarball integrity and the official CLI tag were independently verified.
- alpha dependencies: `playwright@1.63.0-alpha-2026-08-31` and `playwright-core@1.63.0-alpha-2026-08-31`.
- no vendored npm tarball; no automatic package installation or browser download.
- replacement/version drift fails closed and requires a new review; do not silently substitute a version.
- upstream issue: `microsoft/playwright#42500` remains open; no tampering evidence was observed.

**FIGMA:** integration remains link-only; no upstream Figma Skill material is redistributed. The pinned source is governed by the current Figma Developer Terms (effective May 5, 2026), and `FIGMA_WRITE` remains authorization-required/manual-only.

The Codex GitHub import depends on a workspace/account that exposes **Workspace settings > Plugins** and the appropriate installation policy; import does not grant app access or authentication.


## Verificacao minima sem servico externo real

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-orchestrator-coverage.ps1
node .\tests\test-context7-facade.mjs
```

O primeiro comando prova o routing e o fail-closed sem MCP. O segundo usa a facade com transporte sintetico local; ele nao requer Context7 real. Para discovery real, use um `CODEX_HOME` temporario e nao copie autenticacao, cookies, tokens ou config global.
## Desinstalar

```powershell
codex plugin remove frontend-toolkit@frontend-toolkit-local --json
codex plugin marketplace remove frontend-toolkit-local
```

Remova separadamente apenas o diretório de artefato que você criou. Não remova caches ou perfis que pertençam a outros plugins.
