# Contributing

Contribuições são bem-vindas após a publicação do repositório. Mudanças devem preservar simplicidade, rastreabilidade e os gates de custo/mutação.

## Ambiente

1. Leia `AGENTS.md`, `README.md`, `docs/ARCHITECTURE.md` e os locks em `integrations/`.
2. Use as versões pinadas em `integrations/toolchain.lock.json`.
3. Execute `scripts/sync-external-skills.ps1` para materializar checkouts ignorados e junctions locais.
4. Nunca edite upstreams ou snapshots gerados.

## Regras para mudanças

- Não grave secrets, autenticação, perfis, caches, runtimes, fixtures ou paths pessoais.
- Não adicione ferramentas, hooks ou operações 21st sem decisão arquitetural e testes de segurança.
- Atualizações de Impeccable, img2threejs, Shadcn, 21st ou Codex CLI exigem revisão dos locks, licenças, proveniência, compatibilidade e changelog.
- O source permanece sem snapshots; somente build/test/release podem gerá-los.
- Preserve a atribuição de terceiros e não relicencie código upstream.

## Validação mínima

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-plugin-hardening.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-plugin-distribution.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-plugin-official-validation.ps1 -Execute
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-public-release.ps1
git diff --check
```

Mudanças funcionais devem incluir testes proporcionais ao risco. Antes de uma release, execute integralmente `docs/RELEASE-CHECKLIST.md` em ambiente isolado.

## Pull requests

Explique objetivo, alternativas consideradas, impacto de compatibilidade, testes executados e qualquer efeito sobre custos, permissões, licenças ou proveniência. Mantenha cada pull request focado e não inclua artefatos gerados.
