# Integrações

## Persistent release hash evidence

Persistent distribution and release hashes are reconciled only by
**scripts/reconcile-committed-head-locks.ps1**. The reconciler requires a specific
**CommittedHead**, verifies evidence-critical paths against that commit, reproduces two independent
candidates, and compares manifests, ZIP inventories, security inventory, adapters, and upstream
snapshots before writing exactly the observed lock properties.

**DevelopmentWorkingTree** remains a pre-commit diagnostic source and fails closed for persistent
hash writes. Its hashes must never replace committed-HEAD evidence or act as an automatic fallback.

G7-SR2E-R replaced the diagnostic worktree observations
aa79cbb1119db6f9c9e87557f03c98a2bb7ef4cc58eacb6538d224d768d7136f and
81268cf8824297d54113c463e927ac517137eadc296456ad144b8d8c5b82b677 with the twice-reproduced
committed-HEAD observations 669d11cfd754cc0656c810669ec2a662e253898debe2eab63981e19b2b75c3a4
and efcf45ca29616d311a44499c21f65812c0ae60d07e074a7ecf873477dc97df01.

O arquivo `external.lock.json` fixa origem, ref, objeto da ref, commit resolvido, versão, licença, hashes e caminhos de descoberta das Skills externas.

`mcp.lock.json` fixa o provedor oficial Shadcn, pacote, versão e integridade. Para o 21st remoto, fixa endpoint/configuração e registra o snapshot datado de 35 tools, sua classificação, custos evitados e política de revalidação. Jpisnice permanece candidato inativo e `magic-mcp` permanece proibido.

`toolchain.lock.json` também fixa Codex CLI pública estável `0.150.1` e o companion oficial de code mode, usados por caminho explícito na matriz MCP sem substituir a CLI do Desktop.

Os checkouts ficam em `external/` e são ignorados. Nenhuma configuração MCP persistente está ativa; testes usam somente overrides process-locais.

`distribution.lock.json` registra a arquitetura definitiva de snapshots gerados, o SHA-256 agregado da árvore, o gerador, o runtime temporário dos validators e a allowlist automática 21st/search. `scripts/build-plugin-snapshot.ps1` extrai os arquivos próprios de `HEAD` por allowlist exata, rejeita entradas locais inesperadas, materializa somente os SHAs registrados e preserva LICENSE/NOTICE/proveniência upstream. Snapshots permanecem efêmeros e não são fonte de verdade.

`release.lock.json` registra o candidato público `1.3.0`, os hashes da árvore instalável e do payload completo, o builder de marketplace e os estados explícitos `not-published`, `not-created` para tag e release. Durante RELEASE-07B, os hashes observados continuam deliberadamente na última identidade persistida; a reconstrução do committed HEAD e a atualização derivada ficam para LOCK-07C.
As identidades deste lock ainda não representam release publicada, tag `v1.3.0` ou marketplace público.

`distribution.lock.json` também permanece com a observação derivada anterior até LOCK-07C; seus hashes de snapshot e de componentes não são uma authority de versão corrente.

O Impeccable possui `NOTICE.md`, agora pinado por hash em `external.lock.json` e redistribuído. O SHA pinado do img2threejs não possui NOTICE separado. Shadcn é runtime MIT referenciado; 21st é serviço remoto sem código incorporado.
