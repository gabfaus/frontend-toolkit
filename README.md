# Frontend Toolkit

Fundação local e reutilizável para trabalhos de frontend, design, UX, componentes e 3D no Codex.

Status atual: **FTK-01 — arquitetura e planejamento**. Nenhuma dependência externa está instalada e nenhum plugin está empacotado.

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
- `docs/adr/0001-composition-over-vendoring.md`: decisão arquitetural principal.
- `integrations/`, `skills/` e `tests/`: pontos de extensão vazios, sem dependências instaladas.

## Próximo gate

A FTK-02 só deve começar após revisão humana desta fundação e definição do modelo de pinagem das Skills externas.

