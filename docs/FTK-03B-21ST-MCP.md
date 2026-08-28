# FTK-03B — MCP remoto oficial do 21st

Status: **funcional e pronta para revisão de fechamento** em 2026-08-28. Nenhuma mudança desta etapa está staged ou commitada.

## Decisão

A FTK-03B integra somente o MCP remoto oficial do 21st no endpoint exato `https://21st.dev/api/mcp`. O transporte é Streamable HTTP e a autenticação usa bearer token obtido exclusivamente da variável de ambiente `API_KEY_21ST`:

```toml
[mcp_servers.21st]
url = "https://21st.dev/api/mcp"
bearer_token_env_var = "API_KEY_21ST"
```

Essa sintaxe é suportada pelo Codex CLI estável `0.150.1` e consta tanto na documentação oficial do Codex quanto na configuração upstream do plugin 21st. O endpoint e a configuração são pinados; o serviço e suas tools continuam remotos e mutáveis.

## Credential gate e secrets

O teste possui dois modos:

- sem credencial, valida arquivos, lock, endpoint, harness, fronteiras de providers e integridade das Skills, termina com `FTK-03B aguardando API_KEY_21ST fornecida externamente` e não trata o gate como falha arquitetural;
- com credencial, acrescenta handshake, `tools/list`, busca gratuita, execução via Codex e teardown.

A chave não é gravada, copiada, medida, hasheada nem passada na linha de comando. O profile temporário contém somente o nome `API_KEY_21ST`. O teste autenticado verifica que o valor não aparece em arquivos versionáveis e remove profile e fixture no teardown. A configuração persistente do Codex e os PATHs de usuário/máquina permaneceram idênticos antes e depois por comparação de hash/valor.

## Isolamento

`scripts/invoke-21st-codex-test.ps1` resolve a CLI pelo `integrations/toolchain.lock.json`, cria uma fixture Git temporária e expõe Impeccable e img2threejs por junctions efêmeras. O profile:

- habilita o servidor `21st` com allowlist exclusiva da tool `search`;
- desabilita Shadcn;
- não contém secret;
- não ativa hooks.

MCPs herdados da configuração do usuário são desabilitados apenas por overrides process-locais para a sessão sintética. O harness valida que somente 21st ficou habilitado, sem modificar ou corrigir a configuração persistente desses servidores.

## Contrato observado

O teste direto negociou MCP `2025-06-18`, recebeu `serverInfo.name = 21st` e `serverInfo.version = 0.1.0`, e observou transporte stateless sem `mcp-session-id`. A versão informada pelo servidor é apenas metadata observada, não versão de package pinada.

Foram observadas 35 tools:

- discovery/read-only: `search`, `search_picker`, `get_inspiration`, `search_logo`, `list_bookmarks`, `list_bookmark_lists`, `get_bookmark_list`, `list_teams`, `list_team_libraries`, `list_team_lists`, `list_team_components`;
- retrieval: `get_component`, `get_theme`, `get_generation`, `get_take`;
- account/usage read-only: `get_usage`, `get_profile`;
- generation/metered: `generate`, `iterate_generation`;
- mutation/write: `record_inspiration_feedback`, `bookmark`, `create_bookmark_list`, `add_to_list`, `edit_component`, `submit_component`, `withdraw_component`, `resubmit_component`, `remove_component_from_catalog`, `delete_component`, `edit_theme`, `delete_theme`, `edit_template`, `delete_template`, `edit_profile`, `upload_profile_media`.

As categorias usam as annotations e descrições retornadas pelo próprio servidor. `get_component` é read-only tecnicamente, porém pode consumir quota de retrieval; por isso não foi chamado. A descrição de `get_usage` é read-only, mas a tool não foi chamada porque dados de conta não eram necessários.

## Validação funcional

Foi executada somente `search` com a consulta `dashboard`. A busca de metadata retornou resultados diretamente e via Codex CLI estável `0.150.1`.

O prompt do teste Codex foi:

> Use exclusivamente o MCP 21st para pesquisar por componentes relacionados a dashboard. Não gere, instale, publique, edite ou exclua nada. Resuma somente os resultados da busca.

O log da sessão confirmou `mcp: 21st/search (completed)`. Nenhuma outra tool 21st foi exposta ao agente ou acionada.

## Custos e efeitos evitados

A documentação oficial do 21st informa que pesquisa é gratuita, instalações possuem limite diário e 21st AI usa créditos. A FTK-03B não chamou retrieval de componente, geração, iteração, instalação, publicação, edição, exclusão, bookmark, profile ou account/usage. Nenhum crédito de AI foi utilizado e nenhuma operação mutável foi executada.

## Plugin, Skills e Magic

O plugin upstream `21st-dev/codex-plugin` permanece somente como referência. Ele combina o MCP com Skills próprias e atualmente também anuncia workflows adicionais. Não foram instalados o plugin, `@21st-dev/cli` ou quaisquer Skills 21st, incluindo `21st-cli-use`, `21st-ai`, `21st-registry` e `21st-design-sync`.

O repositório histórico `21st-dev/magic-mcp`, o pacote `@21st-dev/magic` e o proxy stdio legado continuam proibidos e ausentes.

Essa separação evita duplicação e ativação automática antes da camada própria de orquestração. A coexistência com Shadcn será testada em gate futuro; nesta etapa os servidores não foram habilitados juntos.

## Atualização futura

Uma revisão manual futura deverá revalidar endpoint, autenticação, protocolo, identificação do servidor, inventário e annotations das tools, comportamento de `search`, preços/limites relevantes e mudanças no plugin oficial. Não há polling ou atualização automática.

O README do plugin upstream anunciava 21 tools, enquanto `tools/list` retornou 35 em 2026-08-28. Essa divergência comprova que o snapshot datado de `integrations/mcp.lock.json` deve prevalecer para compatibilidade, sem presumir estabilidade da superfície remota.

## Fontes oficiais

- [Codex MCP](https://developers.openai.com/codex/mcp)
- [Codex configuration reference](https://developers.openai.com/codex/config-file/config-reference)
- [21st MCP](https://docs.21st.dev/mcp)
- [21st Codex plugin](https://github.com/21st-dev/codex-plugin)
- [Configuração MCP do plugin 21st](https://github.com/21st-dev/codex-plugin/blob/main/.mcp.json)
