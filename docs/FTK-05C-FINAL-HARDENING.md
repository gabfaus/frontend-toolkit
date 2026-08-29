# FTK-05C — Final Plugin Hardening

Status: **READY FOR HUMAN REVIEW** em 2026-08-29. FTK-05B foi fechada antes desta etapa no commit `06f9b93ecec7c576837f5f9193ab250a34cb460a`. FTK-05C não foi staged, commitada, publicada ou enviada por push.

## Resultado

A V1 foi validada como um único plugin reproduzível com três Skills e dois MCPs:

```text
frontend-toolkit/
├── .codex-plugin/plugin.json
├── .mcp.json
├── LICENSE                         # Apache-2.0 do código próprio no artefato
├── THIRD_PARTY_NOTICES.md
├── SNAPSHOT_PROVENANCE.json        # gerado
├── external-skills.lock.json
├── skills/frontend-orchestrator/
├── skills/impeccable/              # snapshot gerado
├── skills/img2threejs/              # snapshot gerado
└── third_party/impeccable/
    ├── LICENSE
    └── NOTICE.md
```

O source tree conserva somente `frontend-orchestrator`; Impeccable e img2threejs são materializados fora da árvore versionada por `scripts/build-plugin-snapshot.ps1`. A documentação oficial atual confirma `.codex-plugin/plugin.json`, `skills` e `mcpServers` como contrato de pacote e o marketplace local como mecanismo de teste: [Package your plugin](https://developers.openai.com/plugins/build/plugins) e [Connect and test your plugin](https://developers.openai.com/plugins/deploy/connect-chatgpt).

## Governança e licenças

`AGENTS.md` mantém a proibição de vendoring manual e abre somente a exceção aprovada para snapshots automáticos de Impeccable/img2threejs, pinados, íntegros, atribuídos, não editáveis e não persistidos sem nova decisão humana.

- código próprio e `frontend-orchestrator`: Apache-2.0;
- Impeccable 4.1.2: Apache-2.0; `LICENSE` e `NOTICE.md` preservados, incluindo atribuição MIT de Platform Design Skills;
- img2threejs 1.5.1: Apache-2.0; o SHA pinado não contém NOTICE separado;
- Shadcn 4.19.0: MIT, resolvido em runtime e não incorporado;
- 21st: serviço MCP remoto, sem código incorporado.

Apache-2.0 é compatível com os snapshots Apache-2.0 e com a referência/runtime MIT. `LICENSE`, `THIRD_PARTY_NOTICES.md`, metadata do plugin, locks e provenance distinguem código próprio de terceiros; nenhum upstream foi relicenciado.

## Determinismo e proveniência

Duas gerações independentes, feitas somente dos SHAs em `integrations/external.lock.json`, produziram a mesma árvore e o mesmo SHA-256 agregado:

`af07a70e4a25f649ca2bc18e281c9f162dd25212a6914e2911498ce6655d8695`

O hash cobre o source plugin, a licença própria copiada para o artefato, as três Skills, licenses, NOTICE, lock materializado e `SNAPSHOT_PROVENANCE.json`. Não há timestamp no snapshot; o cachebuster é aplicado apenas à cópia efêmera do marketplace. Checkouts upstream permaneceram limpos nos SHAs pinados.

## Validators oficiais

Uma venv em `%TEMP%/frontend-toolkit-validator-<id>/` foi criada com CPython 3.14.7 e somente `PyYAML==6.0.3`, obtido do Python Package Index. `PYTHONUTF8=1` foi usado apenas no processo porque `quick_validate.py` usa o encoding local do Windows quando a variável não está definida.

- `plugin-creator/scripts/validate_plugin.py`: PASS no plugin-fonte e na distribuição completa; esse validator validou também o frontmatter das três Skills empacotadas.
- `skill-creator/scripts/quick_validate.py`: PASS em `frontend-orchestrator`.
- o standalone `quick_validate.py` rejeita os campos upstream `version`, `user-invocable` e `argument-hint`; portanto ele não é aplicado como contrato autoral a snapshots externos imutáveis. A distribuição completa continua aceita pelo validator canônico de plugin.

As venvs e snapshots de validação foram removidos integralmente. PyYAML permanece dependência temporária do validator, não do produto.

## MCPs e barreira 21st

`.mcp.json` permaneceu no schema oficial:

- Shadcn: `npx --yes shadcn@4.19.0 mcp`, sem instalação global;
- 21st: `https://21st.dev/api/mcp` e apenas `bearer_token_env_var = API_KEY_21ST`.

Codex suporta `enabled_tools` e approvals para MCP de plugin em `plugins.<plugin>.mcp_servers.<server>` no config do usuário, não dentro do `.mcp.json` distribuído. A fixture isolada adicionou barreiras técnicas `shadcn = ["search_items_in_registries"]` e `21st = ["search"]`. Não foi inventado campo de manifesto. Como o plugin não pode impor essa preferência no config do consumidor, a política semântica do orchestrator continua obrigatória e a configuração plugin-scoped é recomendada como defesa adicional. Referências: [MCP](https://developers.openai.com/codex/mcp) e [Configuration reference](https://developers.openai.com/codex/config-reference).

## Instalação limpa e autenticação isolada

O snapshot foi instalado em uma ação por marketplace local dentro de um `CODEX_HOME` novo. Nenhum `auth.json`, token, cookie, profile, memory, cache, config ou secret do perfil principal foi copiado.

O callback browser para `localhost:1455` não retornou à primeira CLI. O fluxo oficial `codex login --device-auth` foi então usado. Para garantir que a credencial nova pertencesse ao perfil descartável, a fixture definiu `cli_auth_credentials_store = "file"`; a CLI confirmou `Logged in using ChatGPT` e o `auth.json` isolado foi apenas testado por presença, nunca lido. Esse procedimento segue [Authentication — Credential storage and device auth](https://developers.openai.com/codex/auth).

## Discovery e smokes instalados

Uma nova sessão após instalação confirmou:

- Skills: `frontend-orchestrator`, `impeccable`, `img2threejs`;
- MCPs: `shadcn`, `21st`;
- nenhuma capability extra do Frontend Toolkit;
- hooks, Magic MCP, Jpisnice, plugin/Skills oficiais 21st: ausentes.

Resultados comportamentais:

| Smoke | Resultado |
|---|---|
| Orchestrator | PASS; pedido de modal não nomeou ferramenta e roteou para Shadcn; zero 21st |
| Shadcn | PASS; chamada real `search_items_in_registries`, read-only; zero escrita |
| 21st | PASS; routing autônomo e uma chamada `search`; zero metered, mutation ou copy/install |
| img2threejs | PASS; imagem PNG sintética válida, routing correto e evidência somente em `.img2threejs/` |
| Cost gate | PASS; `generate` foi classificado como metered, retornou `authorization-required` e executou zero MCP |

O primeiro assert do cost gate rejeitou apenas o ponto final em `authorization-required.`; a evidência provou que a Skill e o gate funcionaram. O harness versionado aceita pontuação terminal opcional e a operação não foi rerodada.

## Remoção, reinstalação e atualização

- remoção retirou plugin, suas três Skills, seus MCPs e o cache `ftk05c_fixture/frontend-toolkit`;
- reinstalação restaurou versão `0.1.0` e as três Skills;
- o helper oficial gerou `0.1.0+codex.20260829210847`, no formato executável `+codex.YYYYMMDDHHMMSS`;
- nova instalação selecionou essa versão e uma nova sessão pós-update roteou para Shadcn;
- remoção final, remoção do marketplace e logout passaram.

A documentação anterior `+codex.local-YYYYMMDD-HHMMSS` não é usada: prevalecem o helper pinado e o comportamento executável atual.

## Teardown e integridade

O teardown removeu o `CODEX_HOME`, `auth.json`, marketplace, snapshot, caches oficiais baixados dentro da fixture, imagem, `.img2threejs`, logs e workspace sintético. Depois dos testes:

- config Codex principal: inalterado;
- User PATH e Machine PATH: inalterados;
- Impeccable e img2threejs: limpos nos SHAs pinados;
- snapshots persistidos, profiles, marketplaces e fixtures FTK-05C: zero;
- secrets no repositório: zero;
- operações 21st metered/mutáveis/copy-install: zero.

## Riscos e limites remanescentes

- `quick_validate.py` standalone tem schema mais estreito que o validator oficial de plugin para metadata upstream; modificar snapshots para satisfazê-lo violaria a arquitetura aprovada.
- Shadcn via `npx --yes` ainda depende de runtime/cache/rede apesar da versão pinada.
- a superfície remota 21st pode mudar e deve ser reclassificada antes de ampliar a allowlist.
- a barreira `enabled_tools` é configuração do consumidor e não pode ser imposta pelo manifesto atual.
- nenhum snapshot foi commitado no source tree e nenhum artefato foi publicado; uma etapa futura de release deverá decidir onde armazenar o artefato gerado e repetir revisão de licenças/hashes.

## Conclusão técnica

Todos os critérios funcionais da FTK-05 foram atendidos. A FTK-05 está **pronta para fechamento**, condicionada somente à revisão humana e ao futuro commit autorizado da FTK-05C. Publicação, tag, release, push e marketplace público permanecem fora de escopo.
