# Atualização e rollback

## Releases públicas

1. Leia `CHANGELOG.md` e as notas da nova versão.
2. Baixe o novo artefato e valide o SHA-256 publicado.
3. Remova a instalação anterior.
4. Adicione a marketplace do novo artefato e instale `frontend-toolkit@frontend-toolkit-local`.
5. Abra nova sessão e execute discovery e smoke mínimo.

Mantenha o artefato anterior até concluir a validação. Para rollback, remova a versão nova e reinstale a marketplace anterior já validada.

## Desenvolvimento local e cachebuster

Mudanças sem publicação usam o helper oficial `plugin-creator/scripts/update_plugin_cachebuster.py`. Ele preserva a base SemVer e acrescenta metadata no formato executável observado:

```text
1.0.0+codex.YYYYMMDDHHMMSS
```

O cachebuster serve apenas para invalidar o cache local. Não é uma release e não substitui incremento `patch`, `minor` ou `major`.

## Atualizar dependências externas

Atualizações são manuais e independentes:

- **Impeccable/img2threejs:** revisar release/tag, commit, licença/NOTICE, hash do `SKILL.md`, comportamento e proveniência; atualizar locks; sincronizar em checkout limpo; gerar duas snapshots e comparar a árvore.
- **Shadcn:** revisar pacote, integridade npm, licença, runtime mínimo, tools MCP e testes read-only.
- **21st:** revalidar endpoint, autenticação, tool surface, custos/quota e classificação de cada operação. Tool nova ou incerta fica bloqueada.
- **Codex CLI:** revisar schema de plugin, instalação/marketplace, autenticação, config MCP, validators e lifecycle.

Nenhuma dessas mudanças é automática. Consulte `docs/VERSIONING.md` para decidir o impacto SemVer.
