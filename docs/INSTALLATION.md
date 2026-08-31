# Instalação pública

## Escolha do formato

A release pública deve entregar uma marketplace local contendo um único plugin. O repositório-fonte não versiona snapshots externos; `scripts/build-release-candidate.ps1` os gera dos SHAs pinados e cria o candidato instalável.

O artefato contém:

```text
frontend-toolkit-v1.0.0/
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

## Requisitos

Para instalar um artefato pronto: Codex CLI `0.150.1`, Node.js compatível com Shadcn e Python compatível com img2threejs. Para construir do source também são necessários Git, PowerShell e acesso aos upstreams registrados.

Versões validadas:

- Codex CLI `0.150.1`;
- Node.js `24.20.0`;
- CPython `3.14.7`;
- Windows x64 e PowerShell 5.1+.

## Construir do source

Na raiz de um clone limpo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-external-skills.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-candidate.ps1 -Destination .\release-artifacts\v1.0.0
```

A sincronização valida origem, ref, commit, árvore limpa, `SKILL.md` e licenças. O builder falha se o destino existir, sobrepuser o source ou se qualquer checkout divergir do lock.

## Instalar em uma ação

```powershell
codex plugin marketplace add "$PWD\release-artifacts\v1.0.0"
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

A revisão G7-S encontrou bloqueadores nos snapshots atuais de Impeccable e img2threejs. Não instale o candidato para uso por terceiros até que [Security model](SECURITY-MODEL.md) registre a mitigação e uma nova revisão aprove o resultado.

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

## Instalar um artefato publicado futuramente

Baixe o artefato `v1.0.0`, valide seu SHA-256 contra a release e use a pasta extraída como marketplace no comando `codex plugin marketplace add`. A URL e o hash oficiais só devem ser documentados depois da publicação; não há artefato público nesta etapa.

## Desinstalar

```powershell
codex plugin remove frontend-toolkit@frontend-toolkit-local --json
codex plugin marketplace remove frontend-toolkit-local
```

Remova separadamente apenas o diretório de artefato que você criou. Não remova caches ou perfis que pertençam a outros plugins.
