# Frontend Toolkit

Fundação local e reutilizável para trabalhos de frontend, design, UX, componentes e 3D no Codex.

Status atual: **FTK-02A — integração repo-local de Skills externas em revisão**. Os checkouts são locais e ignorados; nenhum MCP, hook ou plugin está configurado.

## Arquitetura-alvo

```text
Frontend Toolkit
├── frontend-orchestrator  # Skill própria, futura
├── impeccable             # Skill externa
├── img2threejs             # Skill externa
├── shadcn-ui               # MCP externo
└── 21st                    # MCP remoto
```

O toolkit será uma camada de composição. Os projetos externos continuarão independentes, com origem, versão e licença rastreadas; não haverá fusão de seus códigos-fonte.

## Conteúdo desta fase

- `AGENTS.md`: limites permanentes de trabalho no repositório.
- `docs/ARCHITECTURE.md`: arquitetura, responsabilidades e decisões.
- `docs/CODEX_ENVIRONMENT.md`: mecanismos nativos e diagnóstico do ambiente atual.
- `docs/DEPENDENCIES.md`: inventário, requisitos, atualização, secrets e licenças.
- `docs/ROADMAP.md`: plano FTK-02 a FTK-05 e critérios de saída.
- `docs/FTK-02A-SKILLS.md`: versões, vínculos, runtimes e resultados da integração de Skills.
- `docs/adr/0001-composition-over-vendoring.md`: decisão arquitetural principal.
- `integrations/`: lock reproduzível e documentação das fontes externas.
- `scripts/`: sincronização fail-closed dos checkouts e junctions.
- `skills/`: ponto reservado ao orchestrator e ao packaging futuro; sem cópias upstream.
- `tests/`: validação estrutural e de descoberta das Skills.

## Próximo gate

A FTK-02A aguarda revisão humana. As mudanças desta etapa não estão staged nem commitadas.
