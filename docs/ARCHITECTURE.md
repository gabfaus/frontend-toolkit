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

Cada integração terá um adaptador declarativo sob `integrations/`, com identidade estável, origem, versão compatível, capacidades permitidas e requisitos. O código externo ficará fora deste repositório ou será materializado apenas por um mecanismo futuro de instalação com pinagem e atribuição explícitas.

## Responsabilidades

### `frontend-orchestrator`

Skill própria que futuramente deverá:

- classificar a intenção: arquitetura visual, implementação, revisão, componentes ou 3D;
- selecionar a menor combinação de capacidades necessária;
- estabelecer ordem de execução e gates de revisão;
- evitar chamadas mutáveis quando descoberta ou leitura forem suficientes;
- detectar conflitos entre recomendações e o design system do projeto-alvo;
- produzir uma síntese única sem ocultar a procedência das contribuições.

Ela não reimplementará Impeccable, img2threejs, Shadcn UI ou 21st.

### Skills externas

- **Impeccable:** linguagem e workflow de design/UX, auditoria e refinamento de frontend. A integração Codex também pode incluir hook de detecção; esse hook exige análise e aprovação separadas.
- **img2threejs:** workflow de reconstrução procedural, validada e animável em Three.js a partir de referência visual.

### MCPs externos

- **Shadcn MCP oficial:** ferramentas do registry oficial para descobrir e consultar componentes; o servidor Jpisnice permanece candidato de fallback inativo até comparação futura.
- **21st MCP oficial:** endpoint remoto `https://21st.dev/api/mcp`, autenticado por bearer obtido de `API_KEY_21ST`. A primeira integração expõe somente busca; o antigo Magic MCP e seu proxy de compatibilidade não fazem parte do toolkit.

## Limites e confiança

- Skills orientam o agente e podem executar scripts incluídos na própria dependência.
- MCPs ampliam a superfície de ação; ferramentas de escrita, instalação, publicação ou exclusão devem exigir intenção explícita e política de aprovação.
- Hooks executam automaticamente em eventos do Codex e, por isso, são opcionais, revisados e habilitados apenas no projeto confiável.
- A configuração de desenvolvimento deve ser local ao repositório. Instalação de usuário será um artefato explícito da FTK-05, nunca um efeito colateral da FTK-02 ou FTK-03.

## Empacotamento futuro

O formato nativo atual de plugin exige `.codex-plugin/plugin.json` e permite, na raiz do plugin, `skills/`, `hooks/`, `.mcp.json`, `.app.json` e `assets/`. A FTK-05 deverá gerar essa camada a partir dos adaptadores validados.

Estrutura de distribuição prevista, ainda não criada:

```text
frontend-toolkit-plugin/
├── .codex-plugin/plugin.json
├── skills/
├── hooks/hooks.json          # somente se aprovado
├── .mcp.json
├── assets/
└── THIRD_PARTY_NOTICES.md
```

O pacote não deve duplicar Skills que já sejam instaladas por outro plugin nem incorporar repositórios completos quando um endpoint ou skill versionada for suficiente.

Durante FTK-02A, as Skills externas permanecem em checkouts independentes ignorados e são expostas por `.agents/skills` somente para desenvolvimento. A documentação de plugins usa `skills/` na raiz do pacote, mas essa diferença não autoriza copiar os upstreams agora. A estratégia definitiva de distribuição pertence à FTK-05 e não deve presumir suporte nativo a dependências entre plugins.

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
