# FTK-02B — runtimes e smoke tests

Validação realizada em 2026-08-27 no Windows x64. Os runtimes são pré-requisitos de máquina, não conteúdo do Git. Nenhum PATH global, MCP, hook, plugin ou secret foi criado.

## Toolchain selecionada

| Runtime | Versão | Instalação user-scoped | Resolução explícita |
|---|---:|---|---|
| Node.js | 24.20.0 LTS (Krypton) | ZIP oficial OpenJS, SHA-256 verificado, extraído sem registrar PATH | `%LOCALAPPDATA%\Programs\FrontendToolkit\node-v24.20.0-win-x64\node.exe` |
| npm | 11.19.0 | incluído na distribuição oficial do Node | `npm.cmd` ao lado de `node.exe` |
| CPython | 3.14.7 | instalador tradicional oficial PSF, por usuário, sem PATH, launcher ou associações | `%LOCALAPPDATA%\Programs\Python\Python314\python.exe` |

O Python Install Manager foi priorizado. O App Installer inicial não terminou de forma observável; depois o Windows reportou o pacote 26.3.240.0 apenas no contexto de implantação elevado, enquanto `pymanager` e seus aliases continuaram indisponíveis ao processo Codex. Por isso foi usado o fallback oficial que a PSF mantém para Python 3.14.

O launcher legado `C:\Windows\py.exe` continuou sem listar instalações. A instalação Python 3.12 informada pelo usuário não estava visível em PATH, launcher ou registro consultado antes desta etapa. Ela não foi removida, atualizada ou procurada dentro de outros projetos; nenhuma `.venv` foi tocada. Assim, a coexistência foi preservada por isolamento, mas a disponibilidade do 3.12 não pôde ser provada neste ambiente.

## Smoke tests

### Impeccable 4.1.2

- `context.mjs`, `pin.mjs` e `doctor.mjs` passaram em `node --check` com Node 24.20.0.
- `context.mjs` foi executado em diretório temporário vazio, com cache/update apontado para fixture local e endpoint inerte.
- O fluxo retornou `NO_PRODUCT_MD`, `RESOLVED_CONTEXT` para a fixture e `MANUAL_DETECTOR_REQUIRED`, confirmando execução funcional sem ativar hook.
- Nenhum arquivo foi criado no checkout externo e `git status --porcelain` permaneceu vazio.

### img2threejs 1.5.1

- Com `PYTHONDONTWRITEBYTECODE=1`, `forge/state.py init` criou estado sintético apenas em diretório temporário.
- `forge/state.py status --json` leu o estado e retornou pipeline ativo em `image-analysis`.
- O teste usa apenas a biblioteca padrão; não instala dependências Python opcionais nem produz cena 3D.
- Nenhuma incompatibilidade com Python 3.14.7 apareceu nesse fluxo e o checkout permaneceu limpo.

## Resolução e isolamento Codex

Os comandos genéricos `node` e `python` não foram adicionados ao PATH. Os testes usam caminhos explícitos. No executor atual, o sandbox bloqueia iniciar executáveis fora das raízes autorizadas; portanto, os smoke tests funcionais precisaram de execução explicitamente aprovada fora do sandbox. Isso não implica uso do Node/Python interno do Codex.

O teste estrutural `codex debug prompt-input` continua verificando os nomes `$impeccable:impeccable` e `$img2threejs` com configuração repo-local. Uma sessão `codex exec --ephemeral --ignore-user-config` carregou ambos os `SKILL.md`, resolveu Node pelo PATH alterado somente no processo e Python pelo caminho explícito, retornando Node 24.20.0 e Python 3.14.7. A sessão não escreveu no repositório nem executou hooks/MCPs. O catálogo remoto de plugins respondeu 503 durante a inicialização, mas isso não afetou a descoberta repo-local. A CLI ainda acrescentou uma entrada de trust do projeto ao `~/.codex/config.toml`; ela foi removida imediatamente e o SHA-256 original `f42ecb86...5f4c` foi restaurado exatamente.

## Atualização

Não há atualização automática. Cada mudança de runtime segue: detecção → avaliação → checksum/origem → smoke tests → atualização deste lock → aprovação → commit. Um novo diretório versionado é instalado lado a lado; a remoção do anterior é uma decisão separada.

## Limitações conhecidas

- O Python Install Manager não ficou chamável pelo processo Codex, apesar do pacote 26.3.240.0 reportado em contexto elevado.
- A instalação tradicional incluiu componentes padrão adicionais antes de a linha de opções ser corrigida; isso aumenta espaço em disco, mas não altera PATH ou outros projetos.
- O sandbox atual exige aprovação para executar os binários em `%LOCALAPPDATA%`.
- A prova independente do Python 3.12 permanece pendente porque ele não está registrado nos mecanismos de máquina inspecionados.
