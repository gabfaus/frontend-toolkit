# Ambiente Codex — inspeção FTK-01

Inspeção realizada em 2026-08-27, no Windows, sem alterar configuração de usuário ou instalar dependências.

## Resultado local

- Codex Desktop com CLI `codex-cli 0.150.0-alpha.8` disponível pelo aplicativo.
- Node.js não está no `PATH` do PowerShell, mas o Codex Desktop fornece runtime Node empacotado em seu cache interno.
- Também há runtimes empacotados de Python, Git e pnpm; esses caminhos são implementação do ambiente e não devem ser gravados como requisito portátil do toolkit.
- Existe configuração de usuário em `~/.codex/config.toml`.
- Não existe `.codex/` nem `.agents/` no diretório que hospedava esta tarefa antes da criação do projeto.
- A CLI informou zero marketplaces em escopo e zero servidores MCP configurados.
- O Desktop mantém caches e plugins próprios e a configuração de usuário contém entradas de marketplaces/plugins do aplicativo. Portanto, a visão da CLI e a do Desktop não são idênticas nesta instalação.
- Nenhum valor de configuração, credential ou secret foi coletado; somente nomes de seções e chaves foram inspecionados.

## Skills

Formato nativo: diretório com `SKILL.md` obrigatório; `scripts/`, `references/`, `assets/` e `agents/openai.yaml` são opcionais.

Locais documentados:

- projeto: `.agents/skills/<skill>/SKILL.md`;
- usuário: `~/.agents/skills/<skill>/SKILL.md`;
- administração/sistema: locais gerenciados ou empacotados.

O ambiente também contém Skills internas sob `~/.codex/skills`. Isso deve ser tratado como armazenamento do produto, não como destino autoral preferencial; para FTK-02, usar `.agents/skills` no projeto.

## MCP

Servidores podem ser configurados em `config.toml` como:

- `stdio`, com `command`, `args`, `cwd` e variáveis permitidas;
- HTTP, com `url`, autenticação e políticas de ferramentas.

Secrets devem ser referenciados por nome de variável (`env_vars`, `bearer_token_env_var` ou `env_http_headers`) e nunca embutidos no arquivo. Plugins podem fornecer `.mcp.json`; configurações de usuário ainda podem limitar estado e ferramentas.

## Plugins locais

O formato oficial atual possui manifesto obrigatório `.codex-plugin/plugin.json`. Um plugin pode apontar para Skills, hooks e MCPs empacotados. Marketplaces locais podem existir no projeto em `.agents/plugins/marketplace.json` ou no usuário em `~/.agents/plugins/marketplace.json`.

Nesta FTK-01 o manifesto e o marketplace não foram criados, pois isso anteciparia o empacotamento reservado à FTK-05.

## Hooks

Hooks podem ficar em:

- `~/.codex/hooks.json` ou inline no `~/.codex/config.toml`;
- `<repo>/.codex/hooks.json` ou inline no `<repo>/.codex/config.toml`;
- `hooks/hooks.json` dentro de plugin.

Hooks locais só carregam em projeto confiável. No Windows, comandos podem precisar de override específico (`commandWindows`/`command_windows`). A FTK-01 não criou hook algum.

## Configuração por projeto e por usuário

Precedência documentada, da maior para a menor: flags/overrides da CLI, `.codex/config.toml` do projeto, profile do usuário, `~/.codex/config.toml`, configuração de sistema e defaults. Camadas `.codex/` do projeto dependem de trust.

Decisão: desenvolver e testar em escopo de projeto; somente a FTK-05 poderá propor instalação de usuário.

## Incompatibilidades e requisitos que afetam a arquitetura

1. **Node ausente do PATH:** integrações via `npx` não podem depender do shell atual sem resolver um runtime estável. O runtime interno do Desktop não é contrato público para scripts do toolkit.
2. **CLI alpha e visão distinta do Desktop:** o empacotamento deve ser testado em uma matriz Desktop + CLI; não presumir que cache interno equivale a marketplace configurado.
3. **Impeccable usa hook Codex:** instalação completa cria `.codex/hooks.json` e requer trust/aprovação. Skill e hook devem ser avaliados separadamente.
4. **img2threejs documenta caminho legado `~/.codex/skills`:** a documentação atual do Codex recomenda `.agents/skills`. FTK-02 precisa testar a integração repo-local em vez de copiar literalmente o caminho upstream.
5. **Shadcn MCP oficial:** o pacote `shadcn@4.19.0` funcionou sem secret com o registry padrão. O teste precisa de um `components.json` sintético e, neste ambiente, da CA do sistema via variável process-local.
6. **21st é serviço remoto e mutável:** usa autenticação própria e contém ferramentas de leitura e escrita. A allowlist e os gates do orchestrator são obrigatórios.
7. **21st já possui plugin Codex próprio:** instalar esse plugin junto do futuro Frontend Toolkit pode duplicar Skills e o nome do MCP. A solução inicial deve integrar somente o endpoint MCP ou declarar incompatibilidade com instalação paralela.

## Preflight FTK-02A

- Git público no `PATH`: `2.49.0.windows.1`, em `C:\Program Files\Git\cmd\git.exe`.
- Node, npm e npx: ausentes do `PATH`.
- Python: ausente; o launcher `C:\Windows\py.exe` existe, mas não encontra uma instalação.
- Symlink de diretório: indisponível sem privilégio administrativo.
- Junction de diretório: suportada sem elevação e escolhida para a descoberta repo-local.

O runtime Node empacotado internamente pelo Codex Desktop não foi usado como dependência do toolkit.

## Resultado FTK-02B

- Node 24.20.0 LTS e npm 11.19.0 foram instalados por ZIP oficial em `%LOCALAPPDATA%\Programs\FrontendToolkit`, sem PATH.
- CPython 3.14.7 foi instalado pelo instalador tradicional oficial da PSF em `%LOCALAPPDATA%\Programs\Python\Python314`, sem mudar launcher ou PATH.
- O Python Install Manager 26.3.240.0 foi reportado somente no contexto de implantação elevado; `pymanager` não ficou acessível ao processo Codex, motivando o fallback oficial.
- Os hashes de PATH de usuário e máquina e o hash de `~/.codex/config.toml` permaneceram iguais ao preflight.
- O sandbox Codex bloqueia executar binários em `%LOCALAPPDATA%` sem aprovação; testes funcionais diretos foram executados fora do sandbox com escopo explícito.
- Consulte `docs/FTK-02B-RUNTIMES.md` e `integrations/toolchain.lock.json` para caminhos portáveis, checksums e evidências.

## Resultado FTK-02C

- `resolve-toolchain.ps1` passou a resolver Node/Python exclusivamente pelo lock e por `%LOCALAPPDATA%`.
- `invoke-codex-test.ps1` injeta Node somente no processo filho e fornece Python por `FTK_PYTHON_PATH`.
- A CLI `0.150.0-alpha.8` voltou a inserir trust do projeto mesmo com `--ephemeral --ignore-user-config`; o harness provou que essa era a única inserção, recusou qualquer diff desconhecido e restaurou os bytes originais.
- A ajuda local promete não carregar `config.toml`, mas não afirma que o arquivo será read-only. A documentação oficial encontrada também não define essa garantia; a intenção da escrita permanece inconclusiva.
- A visão do PATH de usuário difere entre o sandbox normal e o processo elevado. Os hashes ficaram estáveis dentro de cada teste e a toolchain não depende de PATH persistente.

## Resultado FTK-03A

- A CLI bundled `0.150.0-alpha.8` não expôs as tools MCP em `exec` e permanece intacta.
- A CLI pública estável `0.150.1` foi instalada lado a lado em `%LOCALAPPDATA%/Programs/FrontendToolkit/codex/0.150.1`, sem PATH, junto do companion oficial `codex-code-mode-host.exe` exigido pela exposição das tools.
- A CLI estável reutilizou naturalmente o login ChatGPT existente. O profile temporário `-p` foi reconhecido por `mcp list` e removido após o teste.
- `search_items_in_registries` foi exposta e concluída em `codex exec`, retornando `button`; nenhum teste interativo foi necessário.
- Node é resolvido pelo lock e adicionado somente ao PATH filho; `NODE_OPTIONS=--use-system-ca` fica no ambiente MCP e Python permanece explícito em `FTK_PYTHON_PATH`.

## Resultado FTK-03B

- A CLI estável `0.150.1` aceitou `url` + `bearer_token_env_var` em profile temporário e registrou o endpoint `https://21st.dev/api/mcp` sem gravar a chave.
- O handshake direto negociou MCP `2025-06-18`, identificou `21st` `0.1.0` e observou 35 tools; o transporte não forneceu session id e foi encerrado como stateless.
- `search("dashboard")` concluiu diretamente e via `codex exec`; a allowlist expôs somente `search`, Shadcn ficou desabilitado e MCPs herdados foram desabilitados apenas no processo efêmero.
- Nenhuma tool paga, de conta, geração ou escrita foi chamada. Configuração persistente, PATH, Skills, checkouts e hooks permaneceram íntegros.

## Fontes oficiais OpenAI

- [Config basics e precedência](https://learn.chatgpt.com/docs/config-file/config-basic)
- [Advanced config e hooks](https://learn.chatgpt.com/docs/config-file/config-advanced)
- [Build skills](https://learn.chatgpt.com/docs/build-skills)
- [MCP](https://learn.chatgpt.com/docs/extend/mcp)
- [Build plugins](https://developers.openai.com/plugins/build/plugins)
