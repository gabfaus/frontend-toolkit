# Changelog

Este projeto segue [Semantic Versioning 2.0.0](https://semver.org/) e mantém mudanças públicas relevantes neste arquivo.

## [Unreleased]

## [1.3.0] - 2026-09-17

Release pública de versão minor, com features backward-compatible. A tag
anotada imutável `v1.3.0` aponta para o source commit publicado, a GitHub
Release está publicada e os assets oficiais Codex e Claude estão congelados
com os hashes abaixo. O manifesto live do marketplace Claude foi reconciliado
no estado ativo de `main`.

### Added

- Fundação design-motion Phase 1: `taste`, `review-animations` e
  `improve-animations` permanecem `REQUEST_ONLY`; `animate` permanece
  `REGISTERED_NO_HANDLER`.
- Fundação de verificação Browser QA e Accessibility, com superfícies
  `REQUEST_ONLY` e evidência dedicada segura em navegador real
  `PENDING_ENVIRONMENT`.
- Fundação img2threejs procedural Phase 1 como `REQUEST_ONLY`, preservando o
  pipeline GLB existente; Phase 2 permanece `REGISTERED_NO_HANDLER` e preview
  permanece `UNAVAILABLE`.

### Changed

- Convergência do routing/effect model com `QUALITY_FIRST` como default,
  `FIDELITY_FIRST` apenas por intenção semântica explícita e separação entre
  selection, authorization, availability, routing, operation e effect.
- Canonicalização governada de archives externos no fluxo de release, sem
  transformar evidência de worktree em identidade persistente.
- Infraestrutura de testes, cobertura de orchestrator, metadata multi-host e
  validações de release alinhadas à identidade publicada `1.3.0`.

### Release artifacts

- Codex: `frontend-toolkit-codex-v1.3.0.zip`
  SHA-256: `d338790a7c52941048927c6f8bc1cb973a8a797cf49ac2b0e748e15b36c24f73`
- Claude: `frontend-toolkit-claude-v1.3.0.zip`
  SHA-256: `7bb4ab0cf59efa3f02f8e5d9c137a2f7703429f2b829ae69ed928d2df3a6c19f`

### Limitations

- `REQUEST_ONLY` não é execução; nenhuma capability request-only é declarada
  como executável.
- O artefato é **Desktop only** e não é suportado no ChatGPT Web.
- Browser QA e Accessibility permanecem `REQUEST_ONLY`; a evidência dedicada
  segura em navegador real permanece `PENDING_ENVIRONMENT`.
- `animate` permanece `REGISTERED_NO_HANDLER`; img2threejs Phase 2 permanece
  `REGISTERED_NO_HANDLER` e preview permanece `UNAVAILABLE`.
- O 21st permanece search-only; somente `21st/search` é autorizado
  automaticamente.

## [1.2.0] - 2026-09-07

Release candidate congelada para auditoria de publicacao no FTK-09M. Tag, GitHub
Release, marketplace publico e push permanecem pendentes de autorizacao humana.

### Added

- Matriz machine-readable de cobertura do frontend-orchestrator para capabilities, hosts, efeitos e comportamento fail-closed.
- Readiness documentado para Codex, Claude Code e ChatGPT Web.
- Marketplace Codex em `.agents/plugins/marketplace.json` com source local relativo compatível com importação e sincronização GitHub.
- Playwright aceito como `ACCEPT_WITH_RESTRICTIONS`, com integridade verificada, provenance pública ausente explicitamente documentada, dependências alpha divulgadas e sem tarball npm vendorizado ou instalação/download automático.
- O artefato atual é Desktop only no ChatGPT Web; uma distribuição Web-safe fica como follow-up separado.

### Changed

- Locks, manifests e runtime Claude alinhados a candidata 1.2.0.
- @playwright/cli@0.1.19 preservado com aceitacao de source restrita e revisao final de release pendente.

- Preparação pública, documentação de instalação, segurança, contribuição, versionamento e release.

## [1.1.0] - 2026-09-05

Release candidate multi-host; publicação, tag e GitHub Release ainda não foram criadas.

### Added

- Suporte ao Claude Code com preservação do shared core do Codex.
- Empacotamento específico do Claude e lifecycle local de marketplace/cache.
- Adapter Shadcn governado pelo pin `4.19.0`.
- Facade 21st local com superfície search-only.
- Pipeline determinístico de release multi-host a partir do mesmo source commit.

## [1.0.0] - 2026-09-05

Primeira release pública estável, preparada neste gate.

### Added

- `frontend-orchestrator` com routing mínimo e gates de custo/mutação.
- Snapshots determinísticos de Impeccable 4.1.2 e img2threejs 1.5.1.
- Shadcn MCP 4.19.0 e 21st MCP remoto.
- Instalação local em uma unidade, validators oficiais e lifecycle de remoção/reinstalação.
- Runner img2threejs SR2D com `PROJECT_CODE_EXECUTION`, config/JSON/GLB estrutural, ambiente mínimo e state containment integrado.

### Security

- `API_KEY_21ST` exclusivamente por variável de ambiente.
- Somente `21st/search` automaticamente autorizado; nenhuma operação paga ou mutável durante a validação.
