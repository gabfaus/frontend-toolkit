# Testes

Estratégia futura:

- validação estática de manifestos e referências;
- testes de descoberta e ativação de Skills;
- testes de contrato e política dos MCPs;
- smoke tests de hooks em Windows;
- testes de instalação, atualização, rollback e desinstalação do plugin;
- cenários de roteamento e degradação do frontend-orchestrator.

Nenhum runtime ou framework de testes foi instalado na FTK-01.

Na FTK-02A, `test-skill-integration.ps1` valida os checkouts, metadata, recursos, coexistência e ausência de hook sem depender de framework externo.

Na FTK-02B, `test-toolchain.ps1` valida as versões pinadas. Na FTK-02C, ele reutiliza `resolve-toolchain.ps1`, enquanto `test-isolation.ps1` cobre resolução, ausência de mutação persistente, integridade dos checkouts e fronteiras de hook/MCP/plugin. O teste Codex com API é executado separadamente por `scripts/invoke-codex-test.ps1`.

Na FTK-03A, `test-shadcn-mcp.ps1` valida pin/integridade, handshake, inventário de sete ferramentas e chamadas read-only do MCP oficial. Na FTK-03A.1, o lock inclui Codex CLI estável e code-mode host; `scripts/invoke-shadcn-codex-test.ps1` usa profile temporário, fixture efêmera, as duas Skills e somente o MCP Shadcn, exigindo evidência de chamada concluída.

Na FTK-03B, `test-21st-mcp.ps1` possui modos `WithoutCredential` e `WithCredential`. O primeiro valida estaticamente e para no credential gate; o segundo acrescenta handshake HTTP, inventário de 35 tools, `search("dashboard")` gratuita e execução isolada via `scripts/invoke-21st-codex-test.ps1`, sem expor a chave ou chamar tools pagas/mutáveis.

Na FTK-03C, `test-mcp-coexistence.ps1` mantém os mesmos modos de credential gate e chama `scripts/invoke-combined-codex-test.ps1`. O harness compara inventários sem alterar o lock, descobre as duas Skills e habilita apenas Shadcn e 21st. Três sessões sintéticas validam Shadcn-only, 21st `search`-only e a sequência explicitamente roteada Shadcn → 21st. Routing autônomo permanece fora do escopo.

Na FTK-04A, `test-frontend-orchestrator.ps1` valida frontmatter, referências acessíveis, política JSON das quatro capabilities, allowlist 21st, gates de autorização, fallbacks e a matriz JSON de dez cenários. O teste usa Codex CLI estável 0.150.1 apenas para discovery conjunto das três Skills; não executa routing autônomo nem chama MCP.
Na FTK-04B, `scripts/invoke-frontend-routing-test.ps1` separa `FTK_ROUTE` (capability) da evidência MCP (tool concreta). Os dez cenários passaram; o cenário 10 usa imagem sintética, estado limitado a `.img2threejs/`, guard de checkouts e teardown completo, com zero operação 21st paga/mutável.

Na FTK-05A, `test-plugin-packaging.ps1` valida o manifesto do plugin, a Skill própria empacotada, os MCPs pinados, a referência secreta somente por `API_KEY_21ST`, a ausência de hooks/Magic/Jpisnice e o lock dos dois pré-requisitos externos. Não instala nem inicializa o plugin.
