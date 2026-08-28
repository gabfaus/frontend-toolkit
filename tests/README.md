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
