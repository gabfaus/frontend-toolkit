# Versionamento e compatibilidade

Frontend Toolkit segue Semantic Versioning (`MAJOR.MINOR.PATCH`). A versão pública vive em `.codex-plugin/plugin.json`; tags futuras usarão o prefixo `v`, por exemplo `v1.0.0`.

## Incrementos

- **PATCH:** correção compatível de documentação, packaging, validação ou comportamento sem alterar a superfície pública esperada.
- **MINOR:** capability compatível nova, ampliação opt-in ou atualização externa que acrescente comportamento preservando contratos e gates.
- **MAJOR:** mudança incompatível de routing, remoção/renomeação de Skill ou MCP, requisito de instalação incompatível ou redução de garantias de segurança.

Correções de segurança podem exigir qualquer incremento conforme compatibilidade real; não se usa `patch` para esconder breaking change.

## Dependências e impacto

| Mudança | Regra de decisão |
|---|---|
| Impeccable ou img2threejs | Patch se apenas correção interna comprovadamente compatível; minor se ampliar workflow; major se mudar nome, contrato ou requisito incompatível. |
| Shadcn | Patch para correção compatível do pin; minor para nova superfície opt-in; major para mudança incompatível de protocolo, runtime ou comportamento. |
| 21st remoto | Revalidar a cada release. Nova tool não classificada permanece bloqueada. Mudança incompatível de autenticação, custo ou `search` exige major ou suspensão da integração. |
| Codex CLI | Atualização do mínimo validado exige matriz completa; patch/minor se compatível, major se o formato ou lifecycle público mudar. |

## Compatibilidade V1

A V1 valida Windows x64, PowerShell 5.1+, Codex CLI `0.150.1`, Node.js `24.20.0` e CPython `3.14.7`. Requisitos upstream mínimos continuam documentados separadamente. Plataformas não testadas podem funcionar, mas não são declaradas suportadas até haver evidência reproduzível.

Metadata `+codex.<timestamp>` é cachebuster local e não altera precedência SemVer nem cria release.
