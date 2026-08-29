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
