# FTK-09G — integração Figma

Status: integração específica implementada; convergência com o dispatcher e o
packaging global permanece requerida.

## Limite

Esta lane adiciona somente o adapter/policy Figma, provenance, configuração
específica e testes herméticos. Não altera `frontend-orchestrator`, a policy de
segurança comum, o packaging global, Taste/Emil, Playwright/Chrome,
accessibility ou Context7/Storybook.

## Capabilities

- `FIGMA_READ` é a capability default.
- `FIGMA_DESIGN_TO_CODE` usa o adapter oficial `figma-design-to-code` como
  workflow de leitura da origem Figma. Em um pedido concreto, o fluxo oficial
  começa por `get_design_context`; a implementação local continua usando os
  componentes, tokens e convenções do projeto-alvo.
- `FIGMA_WRITE` existe somente como boundary condicional. Não há handler local
  para mutações e a capability não concede `REMOTE_WRITE`.

O mediador em `plugin/frontend-toolkit/security/figma-capability-mediator.mjs`
transforma nomes de tools em decisões FTK tipadas. Ele não é um cliente MCP e
não possui `fetch`, OAuth, seleção de conta/plano/seat ou escrita remota.

## Read allowlist

`get_design_context`, `get_metadata`, `get_screenshot`, `get_variable_defs`,
`get_figjam`, `get_motion_context`, `get_libraries`, `search_design_system` e
`get_code_connect_map`.

`download_assets` não pertence à allowlist: salvar o asset local é um efeito
separado (`LOCAL_PROJECT_WRITE`) e continua manual. `whoami` também não é
automático. Qualquer tool não classificada falha fechado.

## Transports e hosts

O servidor remoto preferencial usa o ID `figma` e
`https://mcp.figma.com/mcp`. O Desktop MCP é uma alternativa separada com o ID
`figma-desktop` e `http://127.0.0.1:3845/mcp`. A policy exige exatamente um
transport ativo e rejeita os dois simultaneamente.

Codex e Claude Code permanecem configurações distintas. Nenhuma regra depende
de prompts MCP específicos do Claude; a policy e o adapter são a fronteira
comum de capability, enquanto a configuração de cada host é selecionada
separadamente.

## Provenance

Fonte única: `figma/mcp-server-guide`, commit
`ae7e5e5f80da20f1dd7445e0c6ae5ac58a5b0bce`, com o conteúdo upstream do
`SKILL.md` verificado pelo SHA-256 registrado em `integrations/figma.lock.json`.
O repositório oficial não contém um arquivo `LICENSE` standalone nesse commit;
seu README direciona aos Figma Developer Terms. Por isso o FTK mantém somente
um adapter link-only e não copia o workflow upstream nem cria snapshot local.

Também não se incorpora o plugin oficial Codex/Figma, não se usa `main`
flutuante, não se conecta conta real e não se executam tools Figma nesta etapa.

## Convergência requerida

Para declarar a integração global pronta, uma etapa futura autorizada precisa
registrar o mediador Figma no dispatcher/policy comum, atualizar as allowlists
fechadas do packaging e ajustar os testes comuns de inventário. Esta lane não
faz essas alterações por estarem fora da file boundary solicitada.
