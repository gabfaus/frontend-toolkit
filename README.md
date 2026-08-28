# Frontend Toolkit

Fundação local e reutilizável para trabalhos de frontend, design, UX, componentes e 3D no Codex.

Status atual: **FTK-03C — funcional e pronta para revisão de fechamento**. FTK-03A foi fechada no commit `a5c95e57f8dac92f639b3f798f9798bcb046c077` e FTK-03B no commit `51fa9c4e6c5fa7b98d424b20f8586abe7a815e63`. As duas Skills e os dois MCPs coexistiram numa mesma fixture Codex 0.150.1, com roteamento explícito e sem operação paga ou mutável.

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
- `docs/FTK-03C-MCP-COEXISTENCE.md`: discovery simultâneo, namespaces, consultas isoladas e uso sequencial dos dois MCPs.
- `docs/adr/0001-composition-over-vendoring.md`: decisão arquitetural principal.
- `integrations/`: lock reproduzível e documentação das fontes externas.
- `scripts/`: sincronização fail-closed dos checkouts e junctions.
- `skills/`: ponto reservado ao orchestrator e ao packaging futuro; sem cópias upstream.
- `tests/`: validação estrutural e de descoberta das Skills.

## Próximo gate

A FTK-03C aguarda revisão humana para fechamento. Suas mudanças não estão staged nem commitadas; não iniciar FTK-04, criar o frontend-orchestrator, empacotar ou testar routing autônomo sem autorização específica.
