# Arquitetura do Frontend Toolkit

## Objetivo

Oferecer ao Codex uma capacidade reutilizável para planejar, construir, revisar e refinar frontend, UX, componentes e experiências 3D. O toolkit coordena capacidades externas especializadas sem assumir propriedade sobre seus códigos-fonte.

## Princípio estrutural

O modelo é **composição por contratos**, não um monorepo de terceiros:

```text
Pedido do usuário
       |
       v
frontend-orchestrator (roteamento, sequência e políticas)
       |
       +--> Impeccable (design, UX e auditoria)
       +--> img2threejs (reconstrução procedural 3D)
       +--> Shadcn MCP oficial (registry e componentes)
       +--> 21st MCP (catálogo, geração e operações do serviço)
```

Cada integração tem um adaptador declarativo sob `integrations/`, com identidade estável, origem, versão compatível, capacidades permitidas e requisitos. O código externo permanece em checkouts independentes durante desenvolvimento e é materializado somente em snapshots de distribuição gerados dos SHAs pinados, atribuídos e descartáveis.

## Responsabilidades

### `frontend-orchestrator`

Skill própria repo-local criada na FTK-04A para:

- classificar a intenção: arquitetura visual, implementação, revisão, componentes ou 3D;
- selecionar a menor combinação de capacidades necessária;
- estabelecer ordem de execução e gates de revisão;
- evitar chamadas mutáveis quando descoberta ou leitura forem suficientes;
- detectar conflitos entre recomendações e o design system do projeto-alvo;
- produzir uma síntese única sem ocultar a procedência das contribuições.

Ela não reimplementará Impeccable, img2threejs, Shadcn UI ou 21st.

A V1 aplica o princípio de menor capacidade: intenção explícita do usuário primeiro, depois a capability principal, e combinações somente para necessidades distintas. Shadcn tem prioridade para componentes oficiais; 21st serve a inspiração/discovery e expõe apenas busca gratuita/read-only por padrão; img2threejs só entra em trabalho 3D explícito ou claramente implícito. O routing autônomo da matriz foi validado funcionalmente na FTK-04B.

### Skills externas

- **Impeccable:** linguagem e workflow de design/UX, auditoria e refinamento de frontend. A integração Codex também pode incluir hook de detecção; esse hook exige análise e aprovação separadas.
- **img2threejs:** workflow de reconstrução procedural, validada e animável em Three.js a partir de referência visual.

### MCPs externos

- **Shadcn MCP oficial:** ferramentas do registry oficial para descobrir e consultar componentes; o servidor Jpisnice permanece candidato de fallback inativo até comparação futura.
- **21st MCP oficial:** endpoint remoto `https://21st.dev/api/mcp`, autenticado por bearer obtido de `API_KEY_21ST`. A operação default do orchestrator é somente busca atualmente classificada como gratuita/read-only; custo, quota, mutação ou classificação incerta exigem autorização explícita. O antigo Magic MCP e seu proxy de compatibilidade não fazem parte do toolkit.

## Limites e confiança

- Skills orientam o agente e podem executar scripts incluídos na própria dependência.
- MCPs ampliam a superfície de ação; ferramentas de escrita, instalação, publicação ou exclusão devem exigir intenção explícita e política de aprovação.
- Hooks executam automaticamente em eventos do Codex e, por isso, são opcionais, revisados e habilitados apenas no projeto confiável.
- A configuração de desenvolvimento deve ser local ao repositório. Instalação de usuário será um artefato explícito da FTK-05, nunca um efeito colateral das etapas de integração ou routing.

## Empacotamento FTK-05

O formato nativo atual de plugin exige `.codex-plugin/plugin.json` e permite, na raiz do plugin, `skills/`, `hooks/`, `.mcp.json`, `.app.json` e `assets/`. A FTK-05 deverá gerar essa camada a partir dos adaptadores validados.

Estrutura fonte criada em `plugin/frontend-toolkit/`:

```text
plugin/frontend-toolkit/
├── .codex-plugin/plugin.json
├── skills/
├── .mcp.json
├── external-skills.lock.json
└── THIRD_PARTY_NOTICES.md
```

O formato oficial não documenta dependências entre plugins ou Skills. A FTK-05B provou que pré-requisitos separados não atendem à instalação única e que snapshots gerados dos SHAs bloqueados atendem. A FTK-05C adotou definitivamente essa arquitetura: checkouts como fonte de verdade, artefato fora da árvore versionada, hash agregado, LICENSE/NOTICE/proveniência e nenhuma edição manual. `AGENTS.md` contém a exceção estreita e o código próprio usa Apache-2.0.

G7-SR1 substitui a descoberta direta por uma arquitetura mediada. `skills/impeccable` e `skills/img2threejs` agora são adapters próprios do FTK; os snapshots byte-equivalentes dos upstreams são materializados exclusivamente em `third_party/upstreams/impeccable` e `third_party/upstreams/img2threejs`. `SNAPSHOT_PROVENANCE.json` distingue os adapters dos payloads upstream e o launcher comum aceita somente operações registradas no manifest de efeitos. O hash observado da árvore G7-SR1 é `626c26e393af4612200b2e5b81f0c23f2cbd381792f6cb92860f299ceefe61ef`.

O schema oficial permite política MCP plugin-scoped em config do consumidor, inclusive `enabled_tools`, mas não no manifesto distribuído. A fixture FTK-05C restringiu Shadcn à consulta de registry e 21st a `search`; o orchestrator continua sendo a barreira semântica obrigatória porque o pacote não pode impor preferências de usuário.

## Distribuição pública FTK-06

O repositório público permanece source-only. `scripts/build-release-candidate.ps1` compõe uma marketplace local determinística ao redor do snapshot, registra a árvore completa e o hash do plugin em `RELEASE_MANIFEST.json` e não adiciona timestamps. O artefato de release — não a árvore-fonte — contém os dois snapshots externos.

SemVer governa a versão pública em `plugin.json`; metadata `+codex.<timestamp>` serve apenas ao cache local. O lock `integrations/release.lock.json` registra a versão candidata, o hash observado e os estados fail-closed de tag/publicação/release.

O mecanismo histórico de junctions de FTK-02A foi substituído por G7-SR1. Os checkouts externos continuam independentes e pinados, mas `.agents/skills` contém somente Skills próprias do FTK. Nenhum `SKILL.md` upstream fica sob uma raiz de discovery.

## Alternativas consideradas

1. **Copiar os quatro projetos para um monorepo:** simplifica um snapshot inicial, mas cria forks implícitos, atualizações difíceis e risco de licença/proveniência. Rejeitada.
2. **Instalar tudo globalmente desde o início:** facilita uso em qualquer projeto, mas aumenta blast radius e dificulta testes reproduzíveis. Adiada até FTK-05.
3. **Compor capacidades por projeto e empacotar depois:** torna versões, permissões e testes auditáveis. Escolhida.

## Fontes do formato Codex

- [Customization: Skills e MCP](https://learn.chatgpt.com/docs/customization/overview)
- [Build skills](https://learn.chatgpt.com/docs/build-skills)
- [MCP no Codex](https://learn.chatgpt.com/docs/extend/mcp)
- [Hooks](https://learn.chatgpt.com/docs/hooks)
- [Plugin structure](https://developers.openai.com/plugins/build/plugins)
