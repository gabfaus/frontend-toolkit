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
