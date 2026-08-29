# Frontend Toolkit

Fundação local e reutilizável para trabalhos de frontend, design, UX, componentes e 3D no Codex.

Status atual: **FTK-05A CLOSED** no commit `ffa7d57e07503741b71455bff6fa6bdbed3255ba`; **FTK-05B READY FOR HUMAN REVIEW**. A instalação limpa favoreceu snapshots externos gerados, ainda condicionados a decisão de governança e licença.

## Arquitetura-alvo

```text
Frontend Toolkit
├── frontend-orchestrator  # Skill própria repo-local V1
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
- `docs/FTK-03C-MCP-COEXISTENCE.md`: discovery simultâneo, namespaces, consultas isoladas e uso sequencial dos dois MCPs.
- `docs/FTK-04A-FRONTEND-ORCHESTRATOR.md`: política V1 de routing, custos, fallbacks, cenários e limites da Skill própria.
- `docs/FTK-04B-FUNCTIONAL-ROUTING.md`: execução funcional dos dez cenários, separação capability/tool, confinamento e teardown.
- `docs/FTK-05A-PLUGIN-PACKAGING.md`: formato oficial, estratégia de distribuição, manifests, segurança e riscos do plugin.
- `docs/FTK-05B-CLEAN-INSTALLATION.md`: comparação empírica, instalação isolada, snapshots determinísticos e recomendação de distribuição.
- `docs/adr/0001-composition-over-vendoring.md`: decisão arquitetural principal.
- `integrations/`: lock reproduzível e documentação das fontes externas.
- `scripts/`: sincronização fail-closed dos checkouts e junctions.
- `.agents/skills/frontend-orchestrator/`: Skill própria descoberta durante desenvolvimento repo-local.
- `skills/`: orientação para a futura distribuição, sem cópias upstream.
- `tests/`: validação estrutural e de descoberta das Skills.

## Próximo gate

A FTK-05A está formalmente CLOSED. A FTK-05B aguarda revisão humana; FTK-05 ainda não pode fechar enquanto governança de snapshots e licença própria permanecerem abertas.
