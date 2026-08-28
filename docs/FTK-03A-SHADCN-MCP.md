# FTK-03A — Shadcn MCP oficial

## Decisão

A integração v1 usa o MCP oficial distribuído pelo pacote `shadcn`, versão fixa `4.19.0`, via `stdio`. A origem, o tarball e a integridade estão registrados em `integrations/mcp.lock.json`. O servidor comunitário `Jpisnice/shadcn-ui-mcp-server` permanece somente como candidato de fallback para uma avaliação futura; nenhuma capacidade diferencial foi validada nesta etapa. `magic-mcp` continua proibido e o 21st permanece reservado à FTK-03B.

Essa escolha reduz o número de intermediários e acompanha o contrato publicado pelo próprio projeto shadcn/ui. A desvantagem é que recursos exclusivos de implementações comunitárias não entram na v1; eles só poderão justificar mudança após comparação reproduzível.

## Execução isolada

`scripts/invoke-shadcn-codex-test.ps1` resolve a CLI pública estável pelo lock ou por `FTK_CODEX_PATH`, cria uma fixture Git sintética em `%TEMP%` e vincula nela as duas Skills externas. Um profile temporário em `$CODEX_HOME/<name>.config.toml` habilita somente Shadcn, desabilita `node_repl` e declara trust para a fixture; ele é removido no teardown. A definição MCP nunca é gravada em `~/.codex/config.toml`. Node entra apenas no `PATH` do processo filho; Python é exposto por caminho explícito.

Um `CODEX_HOME` temporário não foi usado porque `CODEX_HOME` também contém autenticação e sessões. Sem uma credencial efêmera separada, isso exigiria copiar material de autenticação. A CLI estável reutilizou naturalmente o login ChatGPT existente; nenhuma credencial foi copiada ou criada.

`--ignore-user-config` também impede que o profile necessário seja carregado, então ele não é usado neste teste. O profile `-p` é o mecanismo temporário oficialmente anunciado pela ajuda da CLI 0.150.1. O hash de `config.toml`, os PATHs persistentes e a ausência do profile são verificados após a execução.

## Contrato observado

Com Node 24.20.0, o servidor negociou MCP `2025-06-18`, identificou-se como `shadcn` `1.0.0` e expôs sete ferramentas. O startup da sessão Codex pode ultrapassar o default de 30 segundos neste ambiente, por isso o teste usa 120 segundos sem persistir essa configuração:

- `get_project_registries`;
- `list_items_in_registries`;
- `search_items_in_registries`;
- `view_items_in_registries`;
- `get_item_examples_from_registries`;
- `get_add_command_for_items`;
- `get_audit_checklist`.

O smoke funcional pesquisou `button` em `@shadcn` e consultou `@shadcn/button`, usando somente leitura e uma fixture temporária. Nenhum secret foi necessário para o registry padrão. Neste ambiente, o acesso ao registry npm exigiu `NODE_OPTIONS=--use-system-ca`, aplicado somente ao processo de teste.

## Codex CLI compatibility

- **Bundled alpha:** `codex-cli 0.150.0-alpha.8`, pertencente ao Desktop, não expôs as tools do MCP em `codex exec`. Ela não foi substituída nem modificada.
- **Public stable:** `codex-cli 0.150.1`, instalada lado a lado por artefatos oficiais x64 e chamada por caminho absoluto.
- **Registration:** `codex -p <profile> mcp list --json` reconheceu Shadcn habilitado com os argumentos pinados; `node_repl` ficou desabilitado.
- **Tool exposure:** a primeira tentativa falhou fechada por ausência de `codex-code-mode-host.exe`. Após instalar o companion oficial da mesma release, as ferramentas foram expostas.
- **Exec:** `search_items_in_registries` foi iniciada e concluída; a busca retornou `button` e `button-group`, com 33 resultados no total.
- **Interactive:** dispensado, pois `exec` concluiu a chamada sem solicitar aprovação.
- **TLS:** `NODE_OPTIONS=--use-system-ca` precisa estar no campo `env` do servidor MCP; o ambiente geral da sessão não foi propagado ao subprocesso.

Os artefatos e hashes da CLI/companion estão em `integrations/toolchain.lock.json`. A release oficial `0.150.1` permanecia marcada como Latest em 2026-08-28.

## Atualização futura

Uma atualização deve seguir: detectar versão, revisar release/licença/engines, consultar metadados e integridade do registry oficial, executar handshake e chamadas read-only, atualizar o lock, revisar o diff e somente então aprovar commit. Não usar `latest` nem atualização automática.

## Empacotamento futuro

Na FTK-05, a definição equivalente poderá migrar para o mecanismo MCP do plugin, ainda com pacote e argumentos pinados. A FTK-03A não cria `.mcp.json` nem `.codex-plugin/plugin.json`.

## Fontes oficiais

- [shadcn MCP](https://ui.shadcn.com/docs/mcp)
- [shadcn registry](https://ui.shadcn.com/docs/registry)
- [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp)
- [Codex CLI](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
- [Codex environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)
