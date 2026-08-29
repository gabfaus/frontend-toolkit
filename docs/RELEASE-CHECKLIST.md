# Checklist de release

Use esta checklist para toda release. Registre evidências e pare em qualquer divergência.

## Identidade e Git

- [ ] versão SemVer definida em `.codex-plugin/plugin.json`;
- [ ] `CHANGELOG.md` atualizado e data da release definida;
- [ ] worktree e índice limpos no commit candidato;
- [ ] nenhuma alteração concorrente desconhecida;
- [ ] `git diff --check` e validações de encoding passam;
- [ ] tag ainda ausente antes da aprovação humana final.

## Segurança, privacidade e licenças

- [ ] secret scan passa sem credenciais, auth, profiles ou config local;
- [ ] auditoria de paths absolutos/nomes de usuário passa;
- [ ] `.gitignore` e inventário Git excluem caches, runtimes, fixtures, `external/`, junctions e snapshots temporários;
- [ ] `LICENSE`, `THIRD_PARTY_NOTICES.md`, licenças e NOTICE upstream estão corretos;
- [ ] Magic MCP ausente, Jpisnice inativo, hooks ausentes e nenhum código oficial 21st incorporado;
- [ ] somente `21st/search` está automaticamente autorizado;
- [ ] cost gate bloqueia geração sem autorização e nenhuma operação paga/mutável é executada.

## Build e proveniência

- [ ] upstreams reconstruídos exclusivamente dos refs/SHAs pinados;
- [ ] checkouts upstream limpos;
- [ ] duas gerações independentes produzem mesma árvore e mesmo hash agregado;
- [ ] `external-skills.lock.json`, `SNAPSHOT_PROVENANCE.json` e distribution/release locks conferem;
- [ ] artifact SHA-256 registrado e comparado;
- [ ] snapshots existem somente no artefato, não no source.

## Validação e lifecycle

- [ ] testes relevantes passam;
- [ ] validators oficiais passam em venv temporária e o teardown é confirmado;
- [ ] clean-clone reconstrói dependências usando apenas documentação e arquivos versionados;
- [ ] clean install usa `CODEX_HOME` isolado e autenticação oficial, sem copiar credenciais;
- [ ] três Skills e dois MCPs são descobertos em nova sessão;
- [ ] smoke frontend-orchestrator roteia modal/formulário para Shadcn;
- [ ] smoke Shadcn executa consulta read-only;
- [ ] smoke 21st executa somente `search` quando credencial externa existe;
- [ ] smoke img2threejs fica em fixture e realiza teardown;
- [ ] remoção, reinstalação e ausência de estado residual passam;
- [ ] update/cachebuster resolve a nova distribuição.

## Publicação

- [ ] documentação pública e troubleshooting revisados por uma pessoa externa;
- [ ] compatibilidade, riscos e limitações documentados;
- [ ] commit de release aprovado;
- [ ] tag anotada `vMAJOR.MINOR.PATCH` criada somente após autorização;
- [ ] release criada com changelog, artifact e SHA-256 somente após autorização;
- [ ] publicação/marketplace executada somente após autorização;
- [ ] instalação a partir da release pública revalidada.
