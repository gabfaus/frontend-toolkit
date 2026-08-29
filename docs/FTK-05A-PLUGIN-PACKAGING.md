# FTK-05A — Plugin Packaging

Status: **CLOSED** em 2026-08-29 no commit `ffa7d57e07503741b71455bff6fa6bdbed3255ba`.

## Contrato oficial verificado

A documentação oficial atual exige `.codex-plugin/plugin.json` e permite `skills/`, `.mcp.json`, `.app.json`, `hooks/` e assets na raiz do plugin. O manifesto referencia Skills empacotadas com `skills` e MCPs empacotados com `mcpServers`. Não foi encontrado campo oficial para dependências transitivas de outro plugin ou de Skills externas.

FTK-05A usa apenas os campos aceitos pelo validador oficial `plugin-creator`: identidade semver, autoria, metadados de interface, `skills` e `mcpServers`. `.app.json`, marketplace, assets e hooks foram omitidos porque não são necessários para este incremento.

## Estrutura escolhida

```text
plugin/frontend-toolkit/
├── .codex-plugin/plugin.json
├── .mcp.json
├── skills/frontend-orchestrator/
├── external-skills.lock.json
└── THIRD_PARTY_NOTICES.md
```

O `frontend-orchestrator` é materializado byte a byte a partir da Skill própria. Impeccable e img2threejs continuam upstreams independentes e não são copiados para o plugin-fonte.

## Comparação das estratégias externas

| Estratégia | Portabilidade/instalação limpa | Atualização e licença | Offline/duplicação | Complexidade | Decisão |
|---|---|---|---|---|---|
| Snapshots pinados e atribuídos | Melhor: um pacote contém tudo | Exige processo de atualização, notices e revisão por release | Funciona offline, mas duplica código | Média | Tecnicamente adequada para distribuição final, mas proibida agora pela regra de não copiar upstreams |
| Pré-requisitos externos pinados | Menor: instalador precisa resolver duas Skills | Upstreams permanecem independentes; pins e Apache-2.0 ficam explícitos | Depende de cache/rede e evita duplicação | Baixa na fonte, média na instalação | **Escolhida na FTK-05A** |
| Composição oficial entre plugins/Skills | Seria ideal se o host resolvesse dependências | Seria centralizada | Potencialmente limpa | Baixa | Indisponível: o contrato oficial consultado não documenta dependências transitivas |

A escolha é deliberadamente conservadora. Ela preserva o contrato do repositório, mas significa que o artefato FTK-05A isolado ainda não entrega instalação limpa/offline das duas Skills externas. FTK-05B deve decidir entre um instalador transacional de pré-requisitos e uma autorização explícita para gerar snapshots distribuíveis, sem alterar os checkouts upstream.

## MCPs e segurança

- Shadcn usa `npx --yes shadcn@4.19.0 mcp`, conforme o lock.
- 21st usa somente `https://21st.dev/api/mcp` e `bearer_token_env_var: API_KEY_21ST`; nenhum valor secreto existe no pacote.
- O manifesto não incorpora plugin ou Skills oficiais do 21st.
- A política do orchestrator continua permitindo automaticamente somente `21st/search`. Custo, quota, geração, recuperação de código e mutação exigem autorização explícita.
- Magic MCP é proibido; Jpisnice permanece inativo.
- Hooks permanecem ausentes.

## Licenças e atribuições

Impeccable 4.1.2 e img2threejs 1.5.1 são pré-requisitos Apache-2.0 pinados pelos commits registrados em `external-skills.lock.json`. Shadcn 4.19.0 é MIT. O serviço remoto 21st não tem código incorporado. O código próprio permanece `UNLICENSED` até decisão humana de licença; isso bloqueia publicação, mas não o teste local futuro.

## Validação e riscos residuais

`tests/test-plugin-packaging.ps1` valida manifesto, semver, paths, presença do orchestrator, pins MCP, autenticação 21st apenas por nome de variável, ausência de hooks/Magic/Jpisnice e proveniência dos pré-requisitos. O validador oficial `plugin-creator` também deve ser executado quando PyYAML estiver disponível; nenhuma dependência foi instalada apenas para satisfazer esse teste.

Riscos para FTK-05B:

- pré-requisitos externos não são instalados automaticamente pelo schema oficial;
- `npx --yes` pode precisar de rede/cache apesar do pin de versão e integridade registrada;
- a superfície remota 21st pode sofrer drift;
- colisões com Skills/MCPs já instalados precisam ser testadas em perfil efêmero;
- licença do código próprio e experiência de instalação limpa/offline continuam gates humanos.
