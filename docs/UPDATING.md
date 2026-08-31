# Atualização e rollback

## Releases públicas

1. Leia `CHANGELOG.md` e as notas da nova versão.
2. Baixe o novo artefato e valide o SHA-256 publicado.
3. Remova a instalação anterior.
4. Adicione a marketplace do novo artefato e instale `frontend-toolkit@frontend-toolkit-local`.
5. Abra nova sessão e execute discovery e smoke mínimo.

Mantenha o artefato anterior até concluir a validação. Para rollback, remova a versão nova e reinstale a marketplace anterior já validada.

## Desenvolvimento local e cachebuster

Mudanças sem publicação usam o helper oficial `plugin-creator/scripts/update_plugin_cachebuster.py`. Ele preserva a base SemVer e acrescenta metadata no formato executável observado:

```text
1.0.0+codex.YYYYMMDDHHMMSS
```

O cachebuster serve apenas para invalidar o cache local. Não é uma release e não substitui incremento `patch`, `minor` ou `major`.

## Atualizar dependências externas

Uma atualização de versão ou capability é uma mudança de segurança, não uma troca mecânica de pin. Toda atualização exige, antes de entrar na allowlist:

1. diff contra o conteúdo atualmente pinado;
2. release notes upstream;
3. revisão proporcional de segurança;
4. nova classificação de capabilities, tools e efeitos;
5. testes estáticos, comportamentais e adversariais aplicáveis;
6. origem, tag/versão, commit, licença, hashes e provenance;
7. duas builds limpas e determinísticas;
8. regressão do cost gate e das fronteiras de autorização.

### External Skills

Para Impeccable e img2threejs, uma nova versão exige diff integral do escopo redistribuído, inventário de executáveis, revisão de filesystem, rede, subprocessos, shell, ambiente, credenciais e instruções que tentem ampliar autoridade. Revise também symlinks, submodules, nested repositories, bits executáveis, LICENSE/NOTICE e todos os entrypoints novos. Regenere a snapshot somente do SHA aprovado e compare duas árvores; um pin identifica conteúdo, mas não prova segurança.

Não aplique patch silencioso ao checkout ou snapshot. Se a segurança exigir derivação de upstream, pare para decisão arquitetural humana e registre provenance e estratégia de manutenção próprias.

### Shadcn

Revise pacote exato, integridade npm, licença, runtime mínimo, registry/origem, tools MCP, schemas, headers configuráveis e comandos retornados. Tool que apenas produz instrução de instalação não autoriza a execução dessa instrução. Teste somente consultas read-only em fixture até haver intenção explícita de modificar um projeto.

### 21st

Revalide endpoint, autenticação, inventário e semântica de cada tool, custos, quota e efeitos externos. A regra de nascimento é:

```text
NEW TOOL
UNKNOWN
AUTHORIZATION REQUIRED
```

Somente revisão humana explícita pode reclassificar uma tool. Divergência de schema, descrição ou efeito é `DRIFT - HUMAN REVIEW`. Uma tool nova nunca entra automaticamente na allowlist; `search` permanece a única operação automaticamente autorizada enquanto sua semântica atual continuar confirmada.

### Codex CLI e orchestrator

Para Codex CLI, revise schema de plugin, lifecycle de instalação, autenticação, config MCP, validators, sandbox e permissões. Para o orchestrator, revise ordem de autoridade, prompt injection, exfiltração, cost gate, fallbacks e equivalência entre a fonte em `.agents/skills` e a cópia distribuída.

Nenhuma dessas mudanças é automática. Consulte `docs/VERSIONING.md` para decidir o impacto SemVer.
