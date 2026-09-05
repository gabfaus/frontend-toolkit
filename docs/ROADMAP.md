# Plano técnico

Cada etapa termina em revisão humana. Autorização para uma etapa não autoriza a seguinte.

## FTK-02 — Skills externas

Status: **CLOSED**. FTK-02A, FTK-02B e FTK-02C foram fechadas em commits e os testes permanecem reproduzíveis.

### Objetivo

Integrar Impeccable e img2threejs de modo repo-local, independente e atualizável.

### Trabalho previsto

- escolher tags/commits após revisão de release, licença e árvore de arquivos;
- decidir entre checkout externo pinado, submodule ou mecanismo de instalação controlado;
- mapear Skills para `.agents/skills` sem alterar o upstream;
- separar a Skill Impeccable de seu hook opcional;
- validar Python 3.10+ para img2threejs e Node >=22.18 para o Impeccable (concluído na FTK-02B);
- criar testes de descoberta, invocação, atualização e remoção;
- registrar hashes, licença e atribuição.

### Critérios de saída

- as duas Skills aparecem no Codex repo-local;
- nenhuma instalação global;
- nenhuma origem flutuante;
- smoke tests sem modificar projeto externo;
- hook ausente ou aprovado e testado separadamente.

## FTK-03 — MCPs

Status: **CLOSED**. FTK-03A foi fechada no commit `a5c95e57f8dac92f639b3f798f9798bcb046c077`, FTK-03B em `51fa9c4e6c5fa7b98d424b20f8586abe7a815e63` e FTK-03C em `07f2a38abddf83f3659f5b6604c8a06b24033ee8`.

### Objetivo

Integrar Shadcn UI e 21st com secrets externos ao Git e política mínima de ferramentas.

### Trabalho previsto

- manter versão fixa do pacote Shadcn e transporte inicial `stdio` (FTK-03A concluída tecnicamente);
- definir framework/defaults e timeout do Shadcn;
- configurar 21st por HTTP diretamente, sem `magic-mcp` (FTK-03B concluída tecnicamente);
- usar somente nomes de variáveis de ambiente para credenciais;
- inventariar ferramentas com `tools/list` e separar leitura de mutação;
- testar startup, erro sem secret, rate limit, indisponibilidade e teardown;
- documentar dados enviados aos serviços remotos.

### Critérios de saída

- cada MCP inicializa isoladamente e ambos funcionam simultaneamente no ambiente-alvo;
- Impeccable e img2threejs permanecem descobertos na mesma fixture combinada;
- namespaces distintos preservam a seleção explícita e o uso sequencial Shadcn → 21st;
- ausência de secrets produz erro seguro e compreensível;
- ferramentas mutáveis não executam sem intenção explícita;
- nenhum pacote global ou autenticação automática.

## FTK-04 — Frontend Orchestrator

Status: **CLOSED** em 2026-08-29. FTK-04A foi fechada em `03d0676317594c0c2623c1ed40f9abcebd384528`; os dez cenários FTK-04B foram aprovados com zero operação 21st paga/mutável, estado 3D confinado e teardown completo.

### Objetivo

Criar a Skill própria que roteia tarefas e combina resultados sem duplicar capacidades externas.

### Trabalho previsto

- definir taxonomia de intenções e matriz intenção → capacidade;
- estabelecer gates para descoberta, planejamento, mutação, revisão visual e entrega;
- definir precedência quando Impeccable, Shadcn e 21st sugerirem abordagens diferentes;
- bloquear publicação, exclusão e instalação implícitas;
- avaliar metadata/declaração de dependências para o packaging somente quando a FTK-05 autorizar;
- criar cenários de integração e degradação graciosa.

### Critérios de saída

- roteamento determinístico nos casos principais;
- uma ferramenta indisponível não causa ação alternativa perigosa;
- procedência das recomendações permanece visível;
- testes cobrem frontend, UX, componentes e 3D.

## FTK-05 — Testes e empacotamento

Status: **CLOSED** em 2026-08-29. FTK-05A foi fechada no commit `ffa7d57e07503741b71455bff6fa6bdbed3255ba`, FTK-05B em `06f9b93ecec7c576837f5f9193ab250a34cb460a` e FTK-05C em `5ea184ac809ff8368c82c148a68af60aec5c5ebc`.

### Objetivo

Validar o conjunto e gerar um único plugin local instalável, sem publicar.

### Trabalho previsto

- criar `.codex-plugin/plugin.json`, `.mcp.json`, assets e hooks aprovados;
- criar `THIRD_PARTY_NOTICES.md` e decidir licença do código próprio;
- testar em Codex Desktop e CLI compatíveis;
- validar instalação, nova sessão, atualização, desabilitação, desinstalação e rollback;
- detectar conflito com o plugin oficial do 21st e nomes duplicados de Skills/MCPs;
- preparar marketplace local apenas para teste;
- produzir checklist de release, sem publicação.

### Critérios de saída

- pacote passa validações de estrutura e segurança;
- instalação local é reproduzível e reversível;
- matriz de compatibilidade documentada;
- revisão humana aprova licenças, permissões, secrets e distribuição.

FTK-05C atendeu tecnicamente esses critérios em 2026-08-29. A revisão humana aprovou o fechamento; a Frontend Toolkit V1 ficou tecnicamente concluída. Publicação open source não fez parte da FTK-05.

## FTK-06 — Public Release Readiness

Status: **CLOSED** após revisão humana em 2026-08-29. **Frontend Toolkit V1 — PUBLIC RELEASE READY.** Não há tag, release, publicação ou push.

### Objetivo

Tornar o repositório autoexplicativo para terceiros, produzir um candidato local `v1.0.0` determinístico e provar build/instalação a partir de uma cópia limpa do conteúdo versionável, sem alterar a arquitetura funcional da V1.

### Critérios de saída

- documentação pública cobre instalação, uso, atualização, remoção, segurança, contribuição e troubleshooting;
- SemVer, changelog e checklist de release estão versionados;
- auditorias de secrets, privacidade, paths pessoais e inventário Git passam;
- clone/cópia limpa reconstrói os upstreams e gera o mesmo artifact hash;
- instalação limpa descobre três Skills e dois MCPs, preserva cost gate e realiza teardown;
- candidato local `v1.0.0` preserva licenças, notices e proveniência;
- nenhuma tag, release, publicação, push ou snapshot no source é criado.

## Requisitos para iniciar FTK-02

1. Aprovar esta arquitetura de composição.
2. Escolher política de pinagem: tag estável preferida, commit como fallback.
3. Autorizar downloads/checkouts apenas dentro do repositório do toolkit.
4. Escolher submodule versus gerenciador próprio de fontes externas; recomendação inicial: checkouts/cache externos ao pacote e manifesto de lock próprio, evitando submodules até provar necessidade.
5. Autorizar testes repo-locais e definir se o hook do Impeccable fica fora do primeiro incremento.
6. Disponibilizar um Python 3.10+ estável e um Node.js suportado pelo usuário/projeto; não depender do cache interno do Codex.

## G7-S — Plugin / Skills / MCP Security Review

Status: **CLOSED** após G7-S-FA em 2026-09-05. G7-A1R permanece **CLOSED**; esta revisão não reabre nem altera o gate anterior.

A revisão defensiva inicial, registrada em 2026-08-31, confirmou por análise estática e data-flow dois bloqueadores em img2threejs: paths controláveis chegam a escrita após canonicalização sem containment em `<projeto>/.img2threejs`, e configuração controlável pelo projeto chega a `source` do Bash sem parser estrutural ou gate técnico do Toolkit. Esses riscos foram tratados nos gates G7-SR2 e G7-SR3I e revalidados no G7-S-FA; a tabela e a seção final abaixo registram o estado atual.

Shadcn foi revisado com configuração sintética inerte, sem valor de ambiente, credencial ou transferência; somente o registry oficial explicitamente nomeado compõe o smoke read-only. No 21st, apenas `search` permanece automaticamente autorizado; toda tool nova, desconhecida, paga, sujeita a quota ou mutável é `UNKNOWN — AUTHORIZATION REQUIRED`.

Critério de retomada: excluir os componentes bloqueados da distribuição, adotar upstream corrigido e revisto, ou obter decisão humana explícita para manter um derivado com proveniência, ciclo de patches e testes próprios. Política do orchestrator e sandbox do host são defesa em profundidade, não substitutos para enforcement técnico.

As restrições acima valiam para a revisão inicial. O G7-S-FA posterior autorizou somente a aceitação final e um commit documental de fechamento; não autoriza publicação, tag, push nem início automático de fases posteriores.

## G7-SR1 — Adapter foundation

Status: **IMPLEMENTED; AWAITING HUMAN REVIEW** em 2026-08-31.

G7-SR1 implementa somente a fundação da arquitetura `frontend-orchestrator -> FTK capability/security adapters -> upstream snapshots`. As três Skills descobertas são próprias do FTK; Impeccable e img2threejs permanecem funcionalmente representados por adapters, enquanto os snapshots pinados são materializados fora de discovery em `third_party/upstreams/`. O manifest comum registra oito classes de efeito e nega `UNKNOWN`; o launcher comum aceita somente IDs de operações registradas e não oferece entrypoint de script arbitrário.

G7S-001, G7S-002, G7S-003 e G7S-004 permanecem **OPEN**. G7-SR2 deve implementar parser estrutural, auditoria completa dos sinks `CHARACTER_*` e containment canônico de state. G7-SR3 deve implementar parser de contexto estrutural/versionado, isolamento de environment por allowlist, prova ou substituição externa dos controles de update/telemetria e autorização paga realmente mediada pelo host. Nenhuma flag declarativa isolada constitui autorização.

Este gate não autoriza G7-SR2, G7-SR3, G7-A2, instalação real, staging, commit, push, tag, release ou publicação.

### G7-SR2D — img2threejs Safe Execution & Final Integration

Status: **IMPLEMENTED; AWAITING HUMAN REVIEW** em 2026-09-01.

O runner FTK-owned substitui a execução direta do shell upstream por operações registradas com
runtimes pinados, argv estrutural, ambiente allowlisted e `PROJECT_CODE_EXECUTION` explícito. SR2B é
executado antes dos quatro consumidores JSON e confere nodes contra o GLB real; SR2C protege todas as
oito operações de state no boundary. G7S-001 e G7S-002 ficam **IMPLEMENTATION COMPLETE, PENDING
COMMITTED-HEAD REVALIDATION**. G7-SR3,
G7-A2, instalação, staging, commit, push, tag, release e publicação continuam fora deste gate.

### G7-SR2F — img2threejs Security Closeout & Lessons Learned

Status: **READY FOR HUMAN REVIEW** em 2026-09-01.

Após duas builds idênticas do committed HEAD em G7-SR2E e revisão humana aprovada, G7S-001 e
G7S-002 estão **CLOSED**. O ciclo preservado é `OPEN -> IMPLEMENTATION COMPLETE, PENDING
COMMITTED-HEAD REVALIDATION -> MITIGATED -> HUMAN REVIEW -> CLOSED`. As constraints arquiteturais
reutilizáveis estão em [Security Remediation Lessons](SECURITY-REMEDIATION-LESSONS.md).

G7S-003 e G7S-004 continuam **OPEN**. G7-SR3 deve reutilizar a arquitetura mediated-adapter, sem
inferir autorização deste closeout. G7-A2, instalação, staging, commit, push, tag, release e
publicação continuam fora deste gate.

### G7-SR3I — Impeccable Integrated Security Boundary

Status: **IMPLEMENTATION COMPLETE, PENDING COMMITTED-HEAD REVALIDATION** em 2026-09-02.

SR3I integra SR3A e SR3B pela cadeia `authority -> requested operation -> effects -> authorization -> fixed handler`. Contexto local e eventos live conhecidos usam módulos FTK-owned; UNKNOWN falha fechado; telemetry/update automáticos permanecem desligados. Como o host atual não expõe autorização não-forjável ao dispatcher, rede, paid generation, telemetry, live efetivo e mutações persistentes continuam representados, mas retornam `AUTHORIZATION_REQUIRED` antes do handler.

G7S-003 e G7S-004 permanecem **OPEN**. O próximo gate exige commit humano separado, duas builds idênticas do committed HEAD, reconciliação de locks exclusivamente dessa evidência, reexecução completa de segurança/capabilities e revisão humana antes de qualquer promoção para `MITIGATED`.

### G7-S-FA — Final Acceptance & Consolidated Security Closure

Status: **CLOSED** em 2026-09-05 após aceitação final no HEAD limpo `ba10d74c64601573728dffa9b483b1cfdbc4bbe4`.

O packaging, a distribuição completa (install/update/remove/reinstall), a reprodutibilidade e os smokes finais de segurança passaram sem rede, credenciais ou efeitos persistentes. As identidades validadas foram:

- plugin tree: `813de5aed3679e3dc8d5259d0a2670cc2021bc494c032f64ceea196f2ec081e4`;
- artifact tree: `6c0278235fa159a04e773c81f272526eafa544aa4c1b26b9226b25cb5d69a284`;
- raw ZIP: `3be3bc6f6b1c102ea94716d8d6b271706d61ffa893bf5cbaf82dfe90f416a96d`;
- static runtime: `1c69db8e2a571a423506e5bfba9965099dd14a1ed8077a9950f1abd0df4a7ab7`.

G7S-001 e G7S-002 permanecem **CLOSED**. G7S-003 e G7S-004 foram promovidos de `MITIGATED — VERIFIED ON FINAL CLEAN COMMITTED HEAD` para **CLOSED**. Não há HIGH ou CRITICAL remanescente; a remediação de segurança G7-S está completa, a canonicalização está encerrada e o release está pronto para os gates de compatibilidade do Codex e preparação de publicação. Nenhuma dessas fases começa automaticamente.
