# FTK-04A — frontend-orchestrator V1

Status: **funcional e pronta para revisão de fechamento** em 2026-08-28. As mudanças desta etapa não estão staged nem commitadas.

## Objetivo

A FTK-04A cria a primeira política repo-local de decisão do Frontend Toolkit em `.agents/skills/frontend-orchestrator/`. A Skill escolhe quando usar Impeccable, Shadcn, 21st ou img2threejs, como sequenciá-los e quando parar para autorização.

Esta fase define e valida o contrato. Não executa routing autônomo amplo, não altera MCPs, não cria plugin e não testa projetos reais.

## Estrutura

```text
.agents/skills/frontend-orchestrator/
├── SKILL.md
└── references/
    ├── cost-policy.md
    ├── routing-policy.json
    ├── routing.md
    └── scenarios.json
```

`SKILL.md` mantém apenas propósito, decisão principal, gates e rotas para detalhes. `routing.md` explica precedência, combinações e fallbacks. `cost-policy.md` concentra a política mandatória do 21st. Os dois JSON fornecem contratos estruturados e auditáveis para política e cenários.

Não foi criado `agents/openai.yaml`: metadata de interface/dependências não é necessária para discovery repo-local e poderia antecipar decisões de packaging da FTK-05.

## Routing V1

A ordem de decisão é:

1. respeitar escolha, exclusão e limites explícitos do usuário;
2. classificar a intenção principal;
3. selecionar primeiro uma única capability;
4. acrescentar outra somente para entregar resultado distinto e necessário;
5. posicionar autorização imediatamente antes de custo, quota, mutação ou efeito incerto.

Papéis:

- Impeccable: design, UX, crítica visual, hierarquia, layout, tipografia, responsividade e polish;
- Shadcn: componente oficial, registry canônico, exemplos e suporte de implementação;
- 21st: inspiração, alternativas e discovery adicional;
- img2threejs: Three.js, reconstrução procedural, imagem para 3D, assets e scenes.

Para componentes comuns, Shadcn tem prioridade sobre 21st. Para pedidos genéricos de melhoria visual, Impeccable é o início padrão. img2threejs nunca entra em UI 2D normal.

## Menor capacidade e combinações

Disponibilidade não implica uso. Os workflows nova interface, UI existente e interface com 3D são sequências possíveis, não pipelines obrigatórios.

Uma nova interface pode usar Impeccable para direção, Shadcn para componentes, 21st search apenas quando inspiração adicional ajudar, implementação pelo Codex e Impeccable para revisão final. Cada fase é omitida quando não agrega valor.

## Política 21st

A allowlist automática V1 contém somente `search`, desde que a metadata atual continue confirmando operação gratuita, read-only, sem AI credits, quota de copy/install ou mutação.

Exigem autorização explícita antes da chamada:

- geração, `generate`, `iterate_generation` ou consumo de AI credits;
- copy/install ou retrieval sujeito a quota;
- mutation, publish, edit, delete, bookmark ou listas;
- alteração de conta/perfil;
- qualquer tool nova, não classificada ou de custo/efeito incerto.

O snapshot de 35 tools é baseline datado, não verdade eterna. Divergência entre lock e metadata atual fecha o gate: não executar e perguntar.

## Fallbacks

- Shadcn indisponível não transforma 21st em registry oficial equivalente.
- 21st indisponível não bloqueia trabalho possível com Impeccable e Shadcn.
- img2threejs indisponível impede alegar execução ou validação 3D.
- Impeccable indisponível exige declarar ausência da revisão especializada.

Substituição só ocorre quando a alternativa é realmente equivalente e segura.

## Matriz de cenários

`references/scenarios.json` registra dez casos:

1. crítica de layout → Impeccable;
2. modal oficial → Shadcn;
3. inspiração de dashboard → 21st search;
4. imagem para Three.js → img2threejs;
5. “melhore esta tela” → Impeccable primeiro, sem disparar tudo;
6. login profissional → Impeccable e Shadcn quando necessário; 21st opcional;
7. gerar variantes com 21st AI → gate de AI credits;
8. instalar componente 21st → gate de quota/efeito;
9. somente Shadcn → excluir 21st;
10. hero 3D e formulário → img2threejs + Shadcn, Impeccable condicional.

A matriz é contrato estático nesta fase. Execução funcional, avaliação de decisões do agente e correções comportamentais pertencem à FTK-04B.

## Validação

`tests/test-frontend-orchestrator.ps1` valida estruturalmente:

- nome, description e frontmatter;
- diretório próprio normal, não junction;
- inventário e acessibilidade das quatro referências;
- quatro capabilities e papéis;
- princípio de menor capacidade e precedência da intenção do usuário;
- Shadcn-first para componentes oficiais;
- allowlist 21st contendo somente search e doze classes de autorização;
- fallbacks e workflows não obrigatórios;
- dez cenários e expectativas principais;
- ausência de plugin/Skills 21st, Magic, Jpisnice, hooks e manifests;
- integridade das Skills externas;
- discovery simultâneo por Codex CLI 0.150.1.

O `quick_validate.py` fornecido pela skill-creator foi tentado, mas o Python pinado não possui PyYAML. Nenhuma dependência foi instalada. O teste repo-local cobre frontmatter/nome/referências e acrescenta validações semânticas que o quick validator não oferece.

## Discovery observado

Codex CLI estável 0.150.1 anunciou simultaneamente:

- `frontend-orchestrator`;
- `impeccable:impeccable`;
- `img2threejs`.

Não houve colisão de nome, alteração de `~/.codex/config.toml`, PATH persistente ou checkout externo.

## Limites e dívida técnica

- FTK-04A não prova routing comportamental; apenas contrato e discovery.
- Metadata remota 21st deverá ser reavaliada antes de cada operação não trivial.
- A duplicação parcial dos harnesses MCP permanece dívida para FTK-04/05; não foi refatorada.
- Packaging, manifesto, dependências declarativas e instalação pertencem à FTK-05.

## Próximo gate recomendado

FTK-04B deve executar a matriz em fixtures sintéticas e sem mutação, observando decisões reais do agente. Começar pelos casos de capability única e intenção explícita; depois testar combinações e gates 21st sem executar operações pagas. Qualquer teste de geração/copy deve parar antes da chamada e comprovar o pedido de autorização.
