# Frontend Toolkit

Fundação local e reutilizável para trabalhos de frontend, design, UX, componentes e 3D no Codex.

Status atual: **FTK-03B — funcional e pronta para revisão de fechamento**. FTK-03A foi fechada no commit `a5c95e57f8dac92f639b3f798f9798bcb046c077`; o MCP remoto oficial do 21st passou diretamente e via Codex CLI pública estável 0.150.1 sem operação paga ou mutável.

## Arquitetura-alvo

```text
Frontend Toolkit
├── frontend-orchestrator  # Skill própria, futura
├── impeccable             # Skill externa
├── img2threejs             # Skill externa
├── shadcn                  # MCP oficial pinado
└── 21st                    # MCP remoto oficial
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
- `docs/FTK-03B-21ST-MCP.md`: endpoint, autenticação, superfície remota, custos e validação do 21st.
- `docs/adr/0001-composition-over-vendoring.md`: decisão arquitetural principal.
- `integrations/`: lock reproduzível e documentação das fontes externas.
- `scripts/`: sincronização fail-closed dos checkouts e junctions.
- `skills/`: ponto reservado ao orchestrator e ao packaging futuro; sem cópias upstream.
- `tests/`: validação estrutural e de descoberta das Skills.

## Próximo gate

A FTK-03B aguarda revisão humana para fechamento. Suas mudanças não estão staged nem commitadas; não iniciar FTK-03C/FTK-04, empacotamento ou teste simultâneo Shadcn + 21st sem autorização específica.
