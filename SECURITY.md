# Security Policy

## Supported versions

Antes da primeira release pública, somente o branch de desenvolvimento atual recebe correções. Após `v1.0.0`, a linha `1.x` mais recente será suportada; versões anteriores poderão receber correções críticas conforme risco e viabilidade.

## Reporting a vulnerability

Não inclua secrets, tokens, credenciais, dados pessoais ou detalhes exploráveis em uma issue pública. Use o canal privado de security advisory da futura hospedagem pública. Enquanto esse canal ainda não estiver configurado, contate o mantenedor pelo canal privado associado ao repositório e aguarde confirmação antes de divulgar.

O relatório deve conter impacto, componente afetado, versão, passos mínimos de reprodução e mitigação conhecida. Não envie credenciais reais. Problemas relevantes incluem exposição de credenciais, exfiltração, prompt injection com efeito externo, ação MCP não autorizada, supply-chain, path traversal, command injection e bypass de sandbox ou permissão.

## Security model

O plugin não distribui credenciais do mantenedor. Cada usuário fornece sua própria autenticação do host e, opcionalmente, sua própria `API_KEY_21ST`. Somente `21st/search` é automaticamente autorizado pela política do Toolkit; custo, quota, instalação/cópia e mutations exigem autorização explícita.

### Boundary Claude Code

```text
Claude Code
  └── FTK local MCP facade
        └── 21st remote MCP
```

O artefato Claude nunca configura diretamente o endpoint remoto do 21st: seu `.mcp.json` aponta somente para launchers locais dentro do plugin. A facade expõe exclusivamente `search`, falha fechado para ferramentas desconhecidas e não encaminha `tools/list` remoto como superfície local.

`API_KEY_21ST` é uma variável externa `x-api-key`; não é persistida pelo plugin, não é incluída nos artefatos e não deve aparecer em logs. Conteúdo remoto é não confiável e passa por validação, limites de resposta e normalização antes de retornar ao host. Permissões e hooks nativos do Claude são defesa em profundidade, não a enforcement primária: o boundary FTK local deve continuar seguro mesmo sem essa configuração.

O adapter Shadcn continua usando o pin `shadcn@4.19.0` por launcher local governado. Os artefatos Codex e Claude têm configurações de host distintas, mas preservam byte-identical o shared core e os módulos de security comuns.

Skills podem conter e executar código local. Pins, hashes e proveniência identificam o conteúdo, mas não garantem que ele seja seguro. G7-S está **CLOSED**, com zero findings HIGH/CRITICAL remanescentes; a remediação de canonicalização está **CLOSED**. Consulte [Security model](docs/SECURITY-MODEL.md) antes de instalar.

G7-SR1 coloca adapters próprios do FTK na raiz de discovery e mantém snapshots upstream somente em `third_party/upstreams/`. Em G7-SR2D, o runner FTK adiciona `PROJECT_CODE_EXECUTION`, config estrutural, ambiente child-only allowlisted, validação JSON/GLB e state guard no boundary real. Após revalidação do committed HEAD em G7-SR2E e revisão humana, G7S-001 e G7S-002 estão **CLOSED**; o boundary de Impeccable foi integrado em G7-SR3I e validado no gate final abaixo.

G7-SR3I integrou tecnicamente os boundaries SR3A/SR3B. Contexto e eventos conhecidos viram requested operations tipadas antes da avaliação independente de efeitos; UNKNOWN falha fechado e handlers são fixos. O host atual não fornece grant não-forjável ao dispatcher, portanto efeitos sensíveis permanecem `AUTHORIZATION_REQUIRED` quando não autorizados. No G7-S-FA, o HEAD limpo `ba10d74c64601573728dffa9b483b1cfdbc4bbe4` passou a aceitação final: G7S-003 e G7S-004 foram `MITIGATED — VERIFIED ON FINAL CLEAN COMMITTED HEAD` e promovidos a **CLOSED**. G7-S permanece **CLOSED**, com zero findings HIGH/CRITICAL remanescentes; a remediação de canonicalização está **CLOSED** e o release está pronto para os gates de preparação de publicação.

Hooks, Magic MCP, Jpisnice e código oficial do 21st não fazem parte da V1. Fixtures, perfis Codex e autenticação de teste devem ser isolados e descartáveis.

Veja também `docs/ARCHITECTURE.md`, `docs/SECURITY-REMEDIATION-LESSONS.md`, `docs/INSTALLATION.md` e `THIRD_PARTY_NOTICES.md`.
