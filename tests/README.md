# Testes

## Committed-HEAD lock governance

**test-committed-head-lock-governance.ps1** proves that **DevelopmentWorkingTree** can build an
ephemeral diagnostic candidate but cannot persist distribution or release hashes. It also runs the
committed-HEAD reconciler without Apply, requiring two matching builds, manifests, ZIP inventories,
security inventory, adapters, and upstream snapshots before the current locks are accepted.

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

Na FTK-05B, `test-plugin-distribution.ps1` gera duas snapshots efêmeras por `scripts/build-plugin-snapshot.ps1`, compara o hash agregado, instala por marketplace repo-local em `CODEX_HOME` temporário, valida três Skills e dois MCPs no cache, atualiza por cachebuster, remove, reinstala e confirma teardown/config/PATH/checkouts. Nenhum MCP é iniciado.

Na FTK-05C, `test-plugin-official-validation.ps1` cria uma venv descartável com CPython 3.14.7 e `PyYAML==6.0.3`, executa o validator canônico no source e na distribuição, valida `frontend-orchestrator` com `quick_validate.py` e registra a incompatibilidade conhecida desse validator standalone com metadata upstream. `test-plugin-hardening.ps1` agrega licença, notices, locks, packaging, distribuição e contratos dos smokes.

Na FTK-06, `test-public-release.ps1` valida documentação pública, SemVer, metadata, privacidade, secrets, ausência de snapshots no source e, com `-Execute`, gera dois candidatos independentes, compara árvore/hash e remove integralmente a fixture.

Na G7-A1R, `test-release-safety.ps1` valida a allowlist exata do source próprio, a denylist de defesa e ataques sintéticos contra `.env`, auth, credentials, arquivos untracked/ignored/hidden, metadata Git e nomes de chave privada. O teste público também compara duas builds, o inventário completo do manifesto e os paths reais do ZIP.

Na G7-S, `test-archive-security.ps1` exerce checks adversariais sintéticos para traversal, caminhos absolutos, symlink, junction/reparse, submodule, nested `.git` e executável inesperado sem extrair o archive hostil. `test-plugin-security.ps1 -ExpectKnownBlockers` modela paths em memória, canonicaliza cada caso, classifica containment, revisa o data-flow upstream e caracteriza os bloqueadores sem executar os entrypoints. `test-shadcn-security.ps1` faz somente revisão estática: valida o pin, o helper `@shadcn` sem headers, parsing inerte da configuração não confiável e nomes de header, sem definir, ler ou encaminhar valor de ambiente.

Na G7-SR1, `test-adapter-foundation.ps1` valida as oito classes de efeito, `UNKNOWN` fail-closed e a ausência de entrypoint arbitrário no launcher. `test-skill-integration.ps1` prova exatamente três Skills físicas próprias do FTK e hashes upstream fora de discovery. `test-plugin-distribution.ps1` faz duas builds determinísticas e um clean install em `CODEX_HOME` temporário, exigindo adapters em `skills/`, snapshots em `third_party/upstreams/`, provenance separada e exatamente dois MCPs.

Na G7-SR2D, `test-img2threejs-safe-runner.ps1` cobre config JSON e `.env` estrutural, inventário
real de nodes GLB, os quatro mapas SR2B, plano `executable + argv`, allowlist exata child-only via
`ProcessStartInfo`, preservação do environment pai e isolamento entre invocações,
classificação `PROJECT_CODE_EXECUTION`, separação de rede e `init/status/mark/next` reais com fixtures
temporárias. Código de projeto não é executado nesse teste; codec/TypeScript/Vite são validados como
rotas funcionais defensivas sob o boundary do host.

Tipos de evidência:

- **static checks:** pins, locks, instruções, entrypoints, inventários e política machine-readable;
- **synthetic adversarial checks:** archives hostis não extraídos, paths modelados em memória e configuração Shadcn inerte, sem credencial real;
- **behavioral policy-contract checks:** decisões executadas pelo avaliador determinístico da política; não equivalem a uma sessão autenticada do modelo;
- **live MCP checks:** `test-shadcn-mcp.ps1` usa apenas search/view read-only; `test-21st-mcp.ps1 -Mode WithCredential` faz handshake, `tools/list` e `search`, quando uma credencial externa estiver presente.

Enquanto os bloqueadores forem esperados, execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-archive-security.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-plugin-security.ps1 -ExpectKnownBlockers
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-shadcn-security.ps1
```

Sem `-ExpectKnownBlockers`, o teste de segurança ainda termina em erro pelos findings Impeccable
G7S-003/G7S-004. Os defects upstream de path/config continuam byte-preservados no snapshot, mas,
após revalidação do committed HEAD e revisão humana, G7S-001/G7S-002 são reportados como `CLOSED`.
O teste preserva separadamente a caracterização do upstream e o status corrente do finding. O smoke comportamental de uma
sessão Codex isolada ainda exige `CODEX_HOME` temporário autenticado pelo fluxo oficial; os checks
locais não afirmam essa cobertura.

`test-security-finding-status.ps1` confere as referências correntes de status sem reescrever os
checkpoints históricos de G7-SR1 e G7-SR2A/B/C/D.

Quando uma validação dinâmica é desnecessária ou não autorizada, a evidência registra: `DYNAMIC TEST NOT EXECUTED  STATIC/DEFENSIVE REVIEW COMPLETED`.

`scripts/invoke-installed-plugin-smoke.ps1` requer um `CODEX_HOME` autenticado oficialmente sob `%TEMP%`; nunca cria ou copia autenticação. Ele executa novas sessões para orchestrator, Shadcn read-only, 21st/search quando a variável externa está disponível, img2threejs confinado e cost gate sem MCP. Instalação, remoção, reinstalação e cachebuster continuam cobertos por `test-plugin-distribution.ps1`; o ensaio autenticado FTK-05C repetiu esse lifecycle na fixture completa.
Na G7-SR3I, `test-impeccable-integrated-boundary.ps1` reconcilia exatamente os contratos SR3A/SR3B com a policy e o dispatcher comuns. O teste usa apenas contexto/eventos sintéticos e prova requested-operation tipada, efeitos independentes, ausência de autorização fabricável, child environment mínimo, guards empacotados, três Skills, dois MCPs e regressões críticas img2threejs. `test-plugin-hardening.ps1` executa essa regressão como parte do gate compartilhado.

No FTK-vNEXT-03D-01, `test-impeccable-execution-robustness.ps1` cobre o contrato typed de execução dedicada, captura concorrente e bounded de stdout/stderr, exit code, stderr estruturado/malformed, timeout com cleanup, dependência, input inválido, output inválido, rejeição de policy, `UNKNOWN` e a separação histórica do E-011. O timeout default FTK-owned é 120000 ms; os testes usam limites menores apenas nas fixtures sintéticas.
