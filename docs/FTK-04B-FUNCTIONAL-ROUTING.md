# FTK-04B — validação funcional de routing

Status: **CLOSED** por revisão humana em 2026-08-29. Os dez cenários foram aprovados; nenhuma Skill foi alterada.

## Escopo e segurança

A FTK-04B executa os contratos de scenarios.json em fixture sintética e efêmera. O harness usa Codex CLI 0.150.1, habilita somente as buscas read-only aprovadas e compara fixture, configuração Codex e PATH persistente antes/depois. Nenhuma configuração persistente, checkout ou projeto externo foi alterado.

## Correção do cenário 3

O contrato separa capability selecionada (21st) de tool concreta (mcp: 21st/search). O harness passou a normalizar as notações 21st/search e 21st.search para a capability 21st, mantendo uma asserção independente e estrita da chamada search. A Skill e os contratos versionados não foram alterados.

Resultado final: **PASS**; rota 21st, somente 21st/search concluída, zero chamadas pagas/mutáveis e nenhuma mutação.

## Resultados observados

| Cenário | Resultado | Rota | Evidência |
|---|---|---|---|
| 1 | PASS, sessão anterior | impeccable | sem MCP |
| 2 | PASS | shadcn | consulta Shadcn read-only opcional |
| 3 | PASS | 21st | somente 21st/search |
| 4 | PASS | img2threejs | sem MCP |
| 5 | PASS | impeccable | sem MCP |
| 6 | PASS | impeccable | sem MCP |
| 7 | PASS | none | gate; sem MCP |
| 8 | PASS | none | gate; sem MCP |
| 9 | PASS | shadcn | consulta Shadcn read-only opcional; zero outros MCPs |
| 10 | PASS | img2threejs, shadcn | imagem/estado efêmeros; Shadcn read-only opcional; zero 21st |

Todos os runs concluídos reportaram PaidOrMutableCalls = 0 e PersistentMutation = none. O cenário 10 reportou FixtureMutation = ephemeral-only-cleaned e FixtureTeardown = complete; os demais cenários preservaram FixtureMutation = none.

Nos cenários 9 e 10 houve zero chamadas 21st. O profile expôs somente 21st/search, e nenhuma operação 21st metered, generative, copy/install ou mutable esteve disponível ou foi executada.

## Correção e resultado do cenário 9

A revisão humana classificou a falha anterior como ambiguidade do contrato e autorizou o prompt concreto “Use somente Shadcn para encontrar uma solução de modal.”. O harness voltou a exigir rota shadcn e consulta read-only Shadcn. Como o agente emitiu shadcn.search_items_in_registries, o parser passou a separar também a capability Shadcn da tool concreta, preservando a asserção MCP independente.

O cenário 9 passou com somente Shadcn. 21st, img2threejs e Impeccable não foram selecionados. A regressão dirigida do cenário 2 também passou após a mudança compartilhada do parser.

## Correção e resultado do cenário 10

A revisão humana classificou o bloqueio como limitação da fixture e manteve o contrato semanticamente: “Quero uma hero 3D baseada em uma imagem e um formulário de contato abaixo.”. O harness passou a criar SYNTHETIC_REFERENCE.png antes do baseline e autorizou somente o cenário 10 a gravar estado/evidências sob .img2threejs/ na fixture efêmera.

O harness rejeita qualquer novo caminho fora de .img2threejs/, compara os checkouts externos antes/depois, remove a fixture inteira no finally e confirma sua ausência. O resultado foi PASS com rota img2threejs,shadcn, consulta Shadcn read-only, zero chamadas 21st, FixtureMutation = ephemeral-only-cleaned e FixtureTeardown = complete.

A regressão final separou novamente capability de tool para Shadcn: os cenários 2, 9 e 10 exigem a rota Shadcn, mas a consulta search_items_in_registries é opcional quando o agente já possui evidência suficiente. Se houver chamada MCP, somente essa busca read-only é aceita. Os três cenários afetados passaram após a correção; a imagem do cenário 10 passou a ser criada somente imediatamente antes desse caso.

## Conclusão

A FTK-04 cumpre os critérios de saída: roteamento determinístico nos casos principais, gates seguros, procedência capability/tool separada e cobertura funcional de frontend, UX, componentes e 3D. A revisão humana aprovou e encerrou a FTK-04. FTK-05A permanece um gate separado.
