# FTK-02C — isolamento e reprodutibilidade

Esta etapa encerra o gate técnico das Skills sem ampliar suas funcionalidades. Node 24.20.0 e CPython 3.14.7 permanecem pré-requisitos user-scoped fora do Git.

## Decisões

- Python 3.12 deixou de ser relevante para o Toolkit: nenhum consumidor da FTK-02 o utiliza e nenhuma resolução genérica de `python` é necessária.
- CPython 3.14.7 é chamado pelo caminho derivado de `%LOCALAPPDATA%` e pinado no lock.
- O Python Install Manager não é requisito operacional e não será reparado nesta etapa.
- Node entra apenas no `PATH` do processo filho do teste; PATH de usuário e máquina não são modificados.

## Resolver da toolchain

`scripts/resolve-toolchain.ps1` lê `integrations/toolchain.lock.json`, expande caminhos portáveis, exige os dois executáveis e valida as versões exatas. Ele retorna `NodePath`, `NodeDirectory`, `PythonPath`, versões, arquitetura e caminho do lock. Qualquer ausência ou divergência falha de forma explícita.

## Harness Codex

`scripts/invoke-codex-test.ps1`:

1. resolve a toolchain pinada;
2. registra hashes/bytes da configuração Codex e valores persistentes de PATH;
3. injeta Node no PATH somente do processo e publica Python em `FTK_PYTHON_PATH`;
4. executa `codex exec --ephemeral --ignore-user-config` com fixture sintética;
5. compara novamente configuração e PATH;
6. restaura a configuração somente quando a diferença é provadamente uma única inserção do bloco de trust do repositório atual;
7. antes da restauração, relê o hash para recusar overwrite se houver mudança concorrente;
8. valida byte a byte o hash restaurado.

Qualquer mudança diferente do bloco conhecido causa falha sem restauração. O harness não tenta resolver conflitos nem sobrescrever alterações de origem incerta.

## `--ignore-user-config`

Fatos observados na CLI `0.150.0-alpha.8`:

- a ajuda local descreve a opção como “Do not load `$CODEX_HOME/config.toml`; auth still uses `CODEX_HOME`”;
- a sessão não aplicou MCPs/configuração de usuário ao teste;
- mesmo assim, a CLI inseriu um bloco de trust do repositório em `~/.codex/config.toml`;
- o harness detectou a inserção isolada e restaurou o hash original.

A documentação oficial consultada não estabelece uma garantia de ausência de escrita para essa flag. Portanto, a conclusão segura é **C: não há evidência suficiente para afirmar que a escrita de trust é intencional**. O comportamento é tratado como limitação observada da versão atual, não como contrato.

## Resultado controlado

- Impeccable e img2threejs foram descobertos na mesma sessão.
- Node 24.20.0 foi resolvido pela distribuição pública pinada, via PATH process-local.
- CPython 3.14.7 foi resolvido pelo caminho explícito em `FTK_PYTHON_PATH`.
- Configuração Codex: `f42ecb86...5f4c` antes, trust conhecido detectado, `f42ecb86...5f4c` depois.
- PATH persistente no contexto elevado do harness: usuário `83b8fec5...56c9` antes/depois; máquina `c5f7f50e...3b67` antes/depois.
- O sandbox normal e o processo elevado expõem visões diferentes do PATH de usuário. A FTK-02C não investiga a origem dessa diferença e não modifica nenhuma delas; o Toolkit não depende de entradas persistentes.
- Checkouts externos permaneceram limpos e nenhum hook, MCP ou manifesto de plugin apareceu.

## Procedimento futuro

1. Execute `tests/test-isolation.ps1` para validação local sem API.
2. Execute `scripts/invoke-codex-test.ps1` somente em fixture repo-local controlada.
3. Revise warnings de mutação; não aceite restauração de diff desconhecido.
4. Confirme checkouts limpos, ausência de hooks/MCPs e hashes finais.
5. Não promova nova toolchain sem atualizar lock e repetir o gate completo.
