# Frontend Toolkit

Fundação local e reutilizável para trabalhos de frontend, design, UX, componentes e 3D no Codex.

Status atual: **FTK-03A — funcional e pronta para revisão de fechamento**. O MCP oficial passou diretamente e via Codex CLI pública estável 0.150.1; a CLI bundled 0.150.0-alpha.8 permanece intacta.

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
- `docs/FTK-02B-RUNTIMES.md`: toolchain pública, instalação isolada, smoke tests e limitações.
- `docs/FTK-02C-ISOLATION.md`: resolução reproduzível e harness transacional para testes Codex.
- `docs/FTK-03A-SHADCN-MCP.md`: decisão, pin, contrato e isolamento do MCP oficial.
- `docs/adr/0001-composition-over-vendoring.md`: decisão arquitetural principal.
- `integrations/`: lock reproduzível e documentação das fontes externas.
- `scripts/`: sincronização fail-closed dos checkouts e junctions.
- `skills/`: ponto reservado ao orchestrator e ao packaging futuro; sem cópias upstream.
- `tests/`: validação estrutural e de descoberta das Skills.

## Próximo gate

A FTK-03A aguarda revisão humana para fechamento. Suas mudanças não estão staged nem commitadas; 21st permanece fora do escopo até autorização posterior.
