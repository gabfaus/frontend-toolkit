# Plano técnico

Cada etapa termina em revisão humana. Autorização para uma etapa não autoriza a seguinte.

## FTK-02 — Skills externas

Status parcial: FTK-02A fechada em commit e FTK-02B implementada em 2026-08-27 para revisão, sem staging ou commit. Node 24.20.0 LTS e CPython 3.14.7 públicos foram validados por caminhos explícitos.

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

### Objetivo

Integrar Shadcn UI e 21st com secrets externos ao Git e política mínima de ferramentas.

### Trabalho previsto

- escolher versão fixa do pacote Shadcn e transporte inicial `stdio`;
- definir framework/defaults e timeout do Shadcn;
- configurar 21st por HTTP diretamente, sem `magic-mcp`;
- usar somente nomes de variáveis de ambiente para credenciais;
- inventariar ferramentas com `tools/list` e separar leitura de mutação;
- testar startup, erro sem secret, rate limit, indisponibilidade e teardown;
- documentar dados enviados aos serviços remotos.

### Critérios de saída

- ambos os MCPs inicializam no ambiente-alvo;
- ausência de secrets produz erro seguro e compreensível;
- ferramentas mutáveis não executam sem intenção explícita;
- nenhum pacote global ou autenticação automática.

## FTK-04 — Frontend Orchestrator

### Objetivo

Criar a Skill própria que roteia tarefas e combina resultados sem duplicar capacidades externas.

### Trabalho previsto

- definir taxonomia de intenções e matriz intenção → capacidade;
- estabelecer gates para descoberta, planejamento, mutação, revisão visual e entrega;
- definir precedência quando Impeccable, Shadcn e 21st sugerirem abordagens diferentes;
- bloquear publicação, exclusão e instalação implícitas;
- declarar dependências MCP em `agents/openai.yaml` quando o formato estiver validado;
- criar cenários de integração e degradação graciosa.

### Critérios de saída

- roteamento determinístico nos casos principais;
- uma ferramenta indisponível não causa ação alternativa perigosa;
- procedência das recomendações permanece visível;
- testes cobrem frontend, UX, componentes e 3D.

## FTK-05 — Testes e empacotamento

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

## Requisitos para iniciar FTK-02

1. Aprovar esta arquitetura de composição.
2. Escolher política de pinagem: tag estável preferida, commit como fallback.
3. Autorizar downloads/checkouts apenas dentro do repositório do toolkit.
4. Escolher submodule versus gerenciador próprio de fontes externas; recomendação inicial: checkouts/cache externos ao pacote e manifesto de lock próprio, evitando submodules até provar necessidade.
5. Autorizar testes repo-locais e definir se o hook do Impeccable fica fora do primeiro incremento.
6. Disponibilizar um Python 3.10+ estável e um Node.js suportado pelo usuário/projeto; não depender do cache interno do Codex.
