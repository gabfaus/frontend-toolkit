# Integrações

O arquivo `external.lock.json` fixa origem, ref, objeto da ref, commit resolvido, versão, licença, hashes e caminhos de descoberta das Skills externas.

`mcp.lock.json` fixa o provedor oficial Shadcn, pacote, versão e integridade. Para o 21st remoto, fixa endpoint/configuração e registra o snapshot datado de 35 tools, sua classificação, custos evitados e política de revalidação. Jpisnice permanece candidato inativo e `magic-mcp` permanece proibido.

`toolchain.lock.json` também fixa Codex CLI pública estável `0.150.1` e o companion oficial de code mode, usados por caminho explícito na matriz MCP sem substituir a CLI do Desktop.

Os checkouts ficam em `external/` e são ignorados. Nenhuma configuração MCP persistente está ativa; testes usam somente overrides process-locais.

`distribution.lock.json` registra a arquitetura definitiva de snapshots gerados, o SHA-256 agregado da árvore, o gerador, o runtime temporário dos validators e a allowlist automática 21st/search. `scripts/build-plugin-snapshot.ps1` extrai os arquivos próprios de `HEAD` por allowlist exata, rejeita entradas locais inesperadas, materializa somente os SHAs registrados e preserva LICENSE/NOTICE/proveniência upstream. Snapshots permanecem efêmeros e não são fonte de verdade.

`release.lock.json` registra o candidato público `1.0.0`, os hashes da árvore instalável e do payload completo, o builder de marketplace e os estados explícitos `not-published`, `not-created` para tag e release. Os hashes devem mudar sempre que qualquer byte coberto do artifact mudar.

O Impeccable possui `NOTICE.md`, agora pinado por hash em `external.lock.json` e redistribuído. O SHA pinado do img2threejs não possui NOTICE separado. Shadcn é runtime MIT referenciado; 21st é serviço remoto sem código incorporado.
