# Instalação pública

## Escolha do formato

A release pública deverá entregar artefatos separados para Codex e Claude Code. O repositório-fonte não versiona snapshots externos; os builders os geram dos SHAs pinados e criam candidatos instaláveis a partir do mesmo source commit.

O artefato contém:

```text
frontend-toolkit-v1.2.0-codex/
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-candidate.ps1 -Destination .\release-artifacts\v1.2.0-codex
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-claude-release-candidate.ps1 -Destination .\release-artifacts\v1.2.0-claude
```

A sincronização valida origem, ref, commit, árvore limpa, `SKILL.md` e licenças. O builder falha se o destino existir, sobrepuser o source ou se qualquer checkout divergir do lock.

## Instalar em uma ação

```powershell
codex plugin marketplace add "$PWD\release-artifacts\v1.2.0-codex"
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

G7-S está **CLOSED**, com zero findings HIGH/CRITICAL remanescentes, e a remediação de canonicalização está **CLOSED**. Este gate prepara o RC `1.2.0`, mas não cria tag, GitHub Release ou marketplace público. Para uso por terceiros, aguarde os assets oficiais e valide seus SHA-256 contra o manifest externo da futura release.

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

O marketplace usa o asset Claude Code frontend-toolkit-claude-v1.2.0.zip, SHA-256 676b833a9bd3fc79e01bb8c35a253379b5add4b4f13545a9763bd0fc65991089. Esse apontamento registra a identidade congelada; a URL so deve ser usada apos a auditoria/publicacao do FTK-09M.

## Codex, Claude Code e ChatGPT Web

O Codex usa o manifest `.codex-plugin/plugin.json`, a marketplace local gerada pelo builder e as seis Skills descobertas no host: `frontend-orchestrator`, `figma-design-to-code`, `impeccable`, `img2threejs`, `frontend-accessibility` e `playwright-cli`. O payload FTK distribui as quatro Skills FTK-owned; as duas ultimas sao condicionais do host/projeto.

O Claude usa `.claude-plugin/plugin.json`, `claude/mcp.json`, as facades locais e exatamente quatro Skills: `frontend-orchestrator`, `figma-design-to-code`, `impeccable` e `img2threejs`. Accessibility e Playwright nao sao adicionados ao Claude apenas para simetria.

O artifact atual nao e uma distribuicao ChatGPT Web. Ele depende de paths locais, PowerShell, Node, runners locais e, no caso do 21st, interpolacao de ambiente para credencial externa. O texto de policy pode ser lido em um host Web compativel, mas nenhuma capability de runtime e prometida. Um profile WEB-SAFE derivado do mesmo repo depende da confirmacao do contrato do host no FTK-09M.

A marketplace GitHub Codex/remota tambem permanece pendente de confirmacao do schema e lifecycle oficiais. Nao use `.claude-plugin/marketplace.json` como schema Codex.

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
