# Frontend Toolkit

Frontend Toolkit é um plugin open source para Codex que reúne workflows especializados de frontend, UX, componentes e reconstrução 3D sob um roteador único e conservador.

O projeto está licenciado sob Apache-2.0. A V1 técnica foi concluída historicamente, mas a revisão defensiva G7-S bloqueou o candidato `v1.0.0` antes da primeira publicação. Não há tag ou release.

## O que o plugin oferece

```text
Frontend Toolkit
├── frontend-orchestrator   roteamento, precedência e gates de segurança
├── Impeccable              design, UX, crítica e refinamento visual
├── img2threejs             imagem para modelo procedural Three.js
├── Shadcn MCP              consulta ao registry oficial de componentes
└── 21st MCP                inspiração e descoberta remota
```

- **frontend-orchestrator:** escolhe a menor combinação de capacidades necessária e preserva a intenção explícita do usuário.
- **Impeccable:** cobre composição, hierarquia, acessibilidade, responsividade e qualidade de interface.
- **img2threejs:** transforma referências visuais em modelos Three.js construídos em código. G7-SR2D medeia state, GLB, codec, TypeScript e Vite com runtimes/argv/ambiente controlados pelo FTK; os defects preservados no snapshot v1.5.1 não são executados diretamente.
- **Shadcn MCP:** consulta read-only ao registry oficial usando `shadcn@4.19.0`.
- **21st MCP:** serviço remoto em `https://21st.dev/api/mcp`, autenticado somente pela variável `API_KEY_21ST`.

Impeccable e img2threejs permanecem projetos upstream independentes. A descoberta usa adapters próprios do FTK; nenhum `SKILL.md` upstream fica em `.agents/skills` ou em `skills/` do artefato. O build gera snapshots imutáveis e byte-verificados dos SHAs pinados somente sob `third_party/upstreams/`, com provenance separada. O build de release continua extraindo o código próprio de `HEAD` por allowlist exata; o modo `-DevelopmentWorkingTree` existe apenas para validar gates ainda não commitados e mantém as mesmas verificações de composição, reparse points e paths sensíveis.

G7-SR3I integra o Impeccable por uma cadeia fail-closed de autoridade, operação tipada, efeitos independentes e handler fixo. Contexto local passa por extractor e mediator FTK-owned; conteúdo upstream/projeto nunca concede autoridade. Como o plugin atual não recebe evidência host não-forjável, rede, telemetry, paid generation, live efetivo e mutações sensíveis permanecem discoverable, porém retornam `AUTHORIZATION_REQUIRED`. Veja [G7-SR3I](docs/G7-SR3I-IMPECCABLE-INTEGRATED-BOUNDARY.md).

## Política de custo e mutação do 21st

Somente `21st/search` é autorizado automaticamente. Geração, iteração, consumo de créditos ou quota, recuperação/cópia/instalação de código, publicação, edição, exclusão, bookmarks, listas, conta/perfil, qualquer mutation e qualquer tool nova ou de efeito incerto exigem autorização explícita.

O pacote não inclui Magic MCP, Jpisnice, plugin oficial do 21st, Skills oficiais do 21st ou hooks. Quando suportado pelo ambiente, recomenda-se também limitar tecnicamente o MCP 21st a `search`; essa configuração do consumidor complementa, mas não substitui, a política semântica do orchestrator. O 21st é opcional para todas as demais capacidades.

## Requisitos

- Windows x64 e PowerShell 5.1 ou posterior para os scripts versionados;
- Git no `PATH` para construir a partir do source;
- Codex CLI `0.150.1` (versão validada);
- Node.js `24.20.0` (validado; Shadcn requer Node `>=20.18.1`);
- CPython `3.14.7` (validado; img2threejs requer Python `>=3.10`);
- acesso de rede para reconstruir upstreams, iniciar Shadcn e acessar o 21st;
- `API_KEY_21ST` opcional e externa, necessária apenas para uso autenticado do 21st.

As versões e hashes validados estão em `integrations/toolchain.lock.json`, `integrations/external.lock.json` e `integrations/mcp.lock.json`.

## Instalação a partir do source

> **Bloqueado pelo G7-S:** não instale nem recomende o candidato atual. Os comandos abaixo permanecem documentados para reprodução controlada por mantenedores após a mitigação dos findings abertos.

Depois de clonar este repositório:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-external-skills.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-candidate.ps1 -Destination .\release-artifacts\v1.0.0
codex plugin marketplace add "$PWD\release-artifacts\v1.0.0"
codex plugin add frontend-toolkit@frontend-toolkit-local
```

O primeiro comando baixa somente os refs pinados para `external/`. O segundo cria localmente uma marketplace com o plugin completo e os snapshots; `release-artifacts/` é ignorado pelo Git. O source continua sem snapshots.

Veja [Instalação](docs/INSTALLATION.md) para validação, configuração de menor privilégio, instalação por artefato e autenticação isolada.

## Configuração do 21st

Cada usuário autentica sua própria conta Codex e fornece sua própria `API_KEY_21ST`, externamente pelo ambiente ou por um gerenciador de secrets. Nenhuma chave do mantenedor acompanha o plugin. Nunca grave o valor em `.mcp.json`, `config.toml`, scripts, logs ou no repositório. A ausência da variável não impede discovery das três Skills nem uso do Shadcn; apenas deixa o smoke autenticado do 21st indisponível.

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

FTK-06 permanece **CLOSED** como marco histórico de 2026-08-29. A revisão posterior G7-S está **BLOCKED** por findings Critical/High nos snapshots upstream; portanto, o Frontend Toolkit V1 não está atualmente pronto para publicação, instalação por terceiros ou recomendação. O projeto continua sem publicação, tag ou release.
