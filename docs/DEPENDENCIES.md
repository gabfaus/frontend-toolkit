# Dependências externas

Este arquivo começou como inventário da FTK-01. Na FTK-02A, Impeccable e img2threejs foram resolvidos em checkouts repo-locais ignorados e permanecem fora do histórico Git.

| Componente | Papel | Origem | Licença observada | Runtime / acesso | Secret previsto |
|---|---|---|---|---|---|
| Impeccable | Skill de design/UX e detector opcional | `pbakaus/impeccable`, `skill-v4.1.2`, commit `63b04e2530f5c7b41ea83c133daab24f34912456` | Apache-2.0 | Node >=22.18; validado com Node 24.20.0 LTS; hook inativo | nenhum para a integração atual |
| img2threejs | Skill de reconstrução procedural Three.js | `img2threejs/img2threejs`, `v1.5.1`, commit `dede5909be4e494b228c801a55dda47439143932` | Apache-2.0 | Python 3.10+; validado com CPython 3.14.7 | nenhum declarado pelo upstream |
| Shadcn MCP oficial | MCP de registry/componentes | pacote `shadcn@4.19.0`, projeto `shadcn-ui/ui` | MIT | Node.js >=20.18.1; validado via stdio com Node 24.20.0 | nenhum para o registry padrão |
| Jpisnice Shadcn UI MCP Server | candidato comunitário de fallback, inativo na v1 | `Jpisnice/shadcn-ui-mcp-server` | não revalidada nesta etapa | não instalado nem executado | não avaliado |
| 21st MCP oficial | catálogo remoto de componentes, temas e templates | endpoint `https://21st.dev/api/mcp`; plugin `21st-dev/codex-plugin` somente como referência | serviço sujeito a termos; plugin de referência Apache-2.0 | Streamable HTTP; 35 tools observadas em 2026-08-28; busca gratuita validada | bearer por `API_KEY_21ST` |

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

Os runtimes seguem o mesmo gate e estão pinados em `integrations/toolchain.lock.json`. Eles ficam fora do Git e são chamados por caminho explícito; não dependem dos runtimes internos do Codex.

A matriz de compatibilidade MCP usa Codex CLI pública estável `0.150.1` e seu `codex-code-mode-host` oficial, instalados lado a lado por caminho explícito. A CLI bundled do Desktop não é dependência do Toolkit e não foi alterada.

## Secrets

- O repositório contém apenas nomes de variáveis, nunca valores.
- Configuração MCP deve usar `bearer_token_env_var`, `env_vars` ou `env_http_headers` conforme o transporte.
- Arquivos `.env` e variantes estão ignorados; se um `.env.example` surgir no futuro, conterá placeholders não sensíveis.
- Tokens serão criados e inseridos pelo usuário somente na etapa autorizada.
- O registry padrão do MCP oficial Shadcn funcionou sem secret. Registries privados futuros deverão referenciar variáveis de ambiente, nunca valores no Git ou em argumentos.
- O MCP 21st lê `API_KEY_21ST` somente do ambiente do processo. O valor não pertence ao Git, profile, documentação, logs ou argumentos CLI.

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
- [Shadcn MCP oficial](https://ui.shadcn.com/docs/mcp)
- [Jpisnice Shadcn UI MCP Server — candidato inativo](https://github.com/Jpisnice/shadcn-ui-mcp-server)
- [21st MCP](https://docs.21st.dev/mcp)
- [21st Codex plugin de referência](https://github.com/21st-dev/codex-plugin)
