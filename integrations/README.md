# Integrações

O arquivo `external.lock.json` fixa origem, ref, objeto da ref, commit resolvido, versão, licença, hashes e caminhos de descoberta das Skills externas.

`mcp.lock.json` fixa o provedor oficial Shadcn, pacote, versão e integridade. Para o 21st remoto, fixa endpoint/configuração e registra o snapshot datado de 35 tools, sua classificação, custos evitados e política de revalidação. Jpisnice permanece candidato inativo e `magic-mcp` permanece proibido.

`toolchain.lock.json` também fixa Codex CLI pública estável `0.150.1` e o companion oficial de code mode, usados por caminho explícito na matriz MCP sem substituir a CLI do Desktop.

Os checkouts ficam em `external/` e são ignorados. Nenhuma configuração MCP persistente está ativa; testes usam somente overrides process-locais.
