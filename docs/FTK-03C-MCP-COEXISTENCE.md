# FTK-03C — coexistência MCP e Skills

Status: **funcional e pronta para revisão de fechamento** em 2026-08-28. As mudanças desta etapa não estão staged nem commitadas.

## Objetivo e arquitetura

A FTK-03C valida, numa mesma fixture Codex efêmera, as quatro capacidades já aprovadas:

- Skills: `impeccable:impeccable` e `img2threejs`;
- MCPs: `shadcn` oficial por stdio e `21st` oficial por Streamable HTTP.

Não foi criado frontend-orchestrator. Os prompts indicam explicitamente qual servidor usar; portanto, esta etapa prova coexistência e isolamento de namespace, não política autônoma de routing. Essa decisão permanece reservada à FTK-04.

## Profile e isolamento

`scripts/invoke-combined-codex-test.ps1` resolve Node 24.20.0, Codex CLI 0.150.1 e `codex-code-mode-host.exe` pelo lock existente. A fixture Git temporária expõe as duas Skills por junctions e contém somente um `components.json` sintético.

O profile temporário:

- habilita `shadcn@4.19.0` por stdio, com `NODE_OPTIONS=--use-system-ca` somente no ambiente do servidor e allowlist `search_items_in_registries`;
- habilita `https://21st.dev/api/mcp` por HTTP, referencia `bearer_token_env_var = "API_KEY_21ST"` e expõe somente `search`;
- desabilita `node_repl`;
- confia somente na fixture.

MCPs herdados são desabilitados por overrides process-locais. O profile não contém a chave, é protegido por hash e removido no teardown. A fixture também é removida; no Windows, um retry limitado a cinco segundos absorve somente a liberação assíncrona de handles de processos filhos.

## Credential gate e secrets

`tests/test-mcp-coexistence.ps1` possui modos `WithoutCredential` e `WithCredential`. Sem `API_KEY_21ST`, valida contratos estáticos, toolchain, Skills e fronteiras de providers, então termina controladamente no credential gate.

Com credencial, a chave é apenas herdada pelo processo. Ela não é impressa, copiada, hasheada, gravada no profile, passada na linha de comando ou persistida em arquivos/logs versionáveis. O valor real é usado apenas para verificar ausência nos caminhos versionáveis.

## Inventários e namespaces observados

O handshake direto executado dentro do harness observou:

- Shadcn: sete tools, sem drift do pin aprovado;
- 21st: 35 tools, idênticas ao snapshot FTK-03B de `integrations/mcp.lock.json`.

O lock não foi alterado porque não houve diferença. A comparação é dinâmica: uma divergência futura faz o teste falhar e reporta o delta, sem atualizar automaticamente o snapshot remoto.

As tools utilizadas permaneceram namespaced:

- `shadcn/search_items_in_registries`;
- `21st/search`.

Similaridade semântica entre discovery/search não constitui colisão porque servidor e nome qualificado continuam distintos. Nenhum terceiro MCP ficou habilitado na fixture.

## Testes funcionais

1. **Discovery simultâneo:** as duas Skills e os dois MCPs apareceram juntos, sem sobrescrita.
2. **Shadcn-only:** uma busca por `button` chamou e concluiu somente `shadcn/search_items_in_registries`; 21st não foi chamado e a fixture não mudou.
3. **21st-only:** uma busca por `dashboard` chamou e concluiu somente `21st/search`; Shadcn não foi chamado.
4. **Sequencial:** na mesma sessão sintética, a chamada Shadcn iniciou e concluiu antes da chamada 21st, também concluída. Nenhuma terceira tool foi acionada.

O teste de ambiguidade deliberadamente não foi executado. Pedidos sem indicação de fonte exigirão a política do futuro orchestrator.

## Custos e mutações

Para o 21st, somente `search`, já classificada como gratuita/read-only na FTK-03B, foi exposta ao agente. Não foram expostas nem chamadas geração, iteração, retrieval potencialmente sujeito a quota, instalação/copy, bookmark, publicação, edição, exclusão ou account/usage.

O resultado combinado contabilizou zero chamadas pagas ou mutáveis. Shadcn também foi usado somente para busca; nenhum arquivo da fixture ou checkout externo foi alterado.

## Integridade e ocorrências de validação

Impeccable e img2threejs permaneceram descobertos e seus `SKILL.md`/licenças corresponderam aos hashes pinados. Checkouts externos ficaram limpos; plugin/Skills 21st, Magic MCP, Jpisnice e hooks permaneceram ausentes.

Uma execução funcional foi invalidada pelo guard porque a configuração de status line do Codex mudou concorrentemente durante a janela. Não houve marcador da fixture ou do profile combinado no arquivo. A escolha do usuário não foi restaurada; o teste completo foi repetido a partir do novo baseline e confirmou `~/.codex/config.toml`, PATH de usuário e PATH de máquina estáveis antes/depois.

Uma segunda tentativa expôs uma corrida de liberação da fixture vazia no Windows. O teardown recebeu retry curto e limitado e a execução integral subsequente passou. Essa tolerância não relaxa validações de caminho, hash ou mutação.

## Limitações e evolução

- A superfície 21st é remota e pode mudar independentemente do Git; cada revisão deve repetir `tools/list` e avaliar o delta.
- O comportamento do agente tem variabilidade; o teste exige evidência textual de início/conclusão, servidor correto e ordem, e falha fechado diante de desvio.
- Os harnesses individuais e combinado ainda repetem parte da montagem de fixture/profile. Uma extração comum pode ser avaliada em FTK-04/05, sem ampliar esta etapa.
- Coexistência comprovada não implica routing autônomo correto. Taxonomia, precedência e gates de decisão pertencem à FTK-04.

## Resultado

FTK-03A e FTK-03B continuam funcionais. Ambos os MCPs responderam quando explicitamente selecionados, o uso sequencial passou, as duas Skills permaneceram disponíveis, nenhuma operação paga/mutável ocorreu e nenhum secret/configuração/PATH foi persistido pelo Toolkit.
