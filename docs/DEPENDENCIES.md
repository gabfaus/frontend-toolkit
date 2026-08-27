# Dependências externas

Este arquivo é um inventário de planejamento. Nenhuma dependência foi baixada, instalada ou incorporada na FTK-01.

| Componente | Papel | Origem | Licença observada | Runtime / acesso | Secret previsto |
|---|---|---|---|---|---|
| Impeccable | Skill de design/UX e detector opcional | `pbakaus/impeccable` | Apache-2.0 | instalador Node/npx; Skill; hook opcional | nenhum para detector/CLI descritos |
| img2threejs | Skill de reconstrução procedural Three.js | `img2threejs/img2threejs` | Apache-2.0 | Python 3.10+; visão/browser do host; Three.js no projeto-alvo | nenhum declarado pelo upstream |
| Shadcn UI MCP Server | MCP de contexto/componentes | `Jpisnice/shadcn-ui-mcp-server` | MIT | Node.js >= 18; stdio via npx ou servidor local | `GITHUB_PERSONAL_ACCESS_TOKEN` recomendado, sem scopes segundo upstream |
| 21st MCP | MCP remoto do serviço atual | `https://21st.dev/api/mcp` | serviço sujeito a termos; plugin Codex de referência é Apache-2.0 | HTTP MCP; acesso de rede | `API_KEY_21ST` |

## Estratégia de aquisição

- Não usar branch flutuante nem `@latest` em instalação reproduzível.
- Registrar para cada integração: URL canônica, tag/versão ou commit, data de verificação, checksum quando aplicável e versão mínima do Codex/runtime.
- Preferir checkout independente ou artefato publicado com lock, sem copiar arquivos manualmente para dentro do código próprio.
- Para Skills, avaliar nesta ordem: suporte repo-local nativo do upstream, checkout externo com link controlado, e adaptador mínimo que referencia a instalação. A escolha final pertence à FTK-02.
- Para MCP stdio, pin do pacote e lockfile local. Para MCP remoto, pin não é possível no mesmo sentido; registrar contrato observado e executar testes de compatibilidade.

## Estratégia de atualização

1. Detectar nova versão sem aplicá-la.
2. Ler changelog, licença e alterações de instalação/configuração.
3. Atualizar um componente por vez em branch de manutenção.
4. Rodar contrato, smoke tests e testes de conflito.
5. Atualizar inventário e atribuições.
6. Submeter diff para revisão humana antes de promover.

Não haverá atualização automática silenciosa. Dependências invocadas por pacote devem usar versão fixa, não `latest`.

## Secrets

- O repositório contém apenas nomes de variáveis, nunca valores.
- Configuração MCP deve usar `bearer_token_env_var`, `env_vars` ou `env_http_headers` conforme o transporte.
- Arquivos `.env` e variantes estão ignorados; se um `.env.example` surgir no futuro, conterá placeholders não sensíveis.
- Tokens serão criados e inseridos pelo usuário somente na etapa autorizada.
- O token GitHub do Shadcn deve ter o menor privilégio possível e nunca ser passado em argumento de linha de comando, pois argumentos podem aparecer em logs e listas de processos.

## Licenças e atribuições

- Manter `THIRD_PARTY_NOTICES.md` no pacote futuro, com projeto, copyright, URL, versão e texto/aviso exigido.
- Preservar `LICENSE` e `NOTICE` quando a forma de redistribuição exigir.
- Não remover cabeçalhos dos arquivos upstream.
- Verificar novamente licenças na versão efetivamente pinada; a tabela acima é um levantamento de 2026-08-27, não parecer jurídico.
- A licença do código próprio do Frontend Toolkit ainda não foi escolhida. Não publicar até essa decisão.
- O 21st MCP é também um serviço: além da licença de qualquer cliente/plugin, FTK-03 deve revisar termos, privacidade, retenção e limites do serviço.

## Instalação local versus global

**Projeto-local (padrão de desenvolvimento):** isolamento, reprodução e remoção simples; requer ativação em cada projeto consumidor.

**Usuário/global (somente distribuição madura):** conveniência em todos os projetos; maior blast radius, risco de colisão de nomes e atualizações menos controladas.

Decisão: FTK-02 a FTK-04 permanecem repo-local. FTK-05 deverá oferecer instalação por plugin como caminho de usuário, com desinstalação e rollback documentados.

## Fontes upstream

- [Impeccable](https://github.com/pbakaus/impeccable)
- [img2threejs](https://github.com/img2threejs/img2threejs)
- [Shadcn UI MCP Server](https://github.com/Jpisnice/shadcn-ui-mcp-server)
- [21st MCP](https://docs.21st.dev/mcp)
- [21st Codex plugin de referência](https://github.com/21st-dev/codex-plugin)

