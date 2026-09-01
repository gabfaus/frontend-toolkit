# Security Policy

## Supported versions

Antes da primeira release pública, somente o branch de desenvolvimento atual recebe correções. Após `v1.0.0`, a linha `1.x` mais recente será suportada; versões anteriores poderão receber correções críticas conforme risco e viabilidade.

## Reporting a vulnerability

Não inclua secrets, tokens, credenciais, dados pessoais ou detalhes exploráveis em uma issue pública. Use o canal privado de security advisory da futura hospedagem pública. Enquanto esse canal ainda não estiver configurado, contate o mantenedor pelo canal privado associado ao repositório e aguarde confirmação antes de divulgar.

O relatório deve conter impacto, componente afetado, versão, passos mínimos de reprodução e mitigação conhecida. Não envie credenciais reais. Problemas relevantes incluem exposição de credenciais, exfiltração, prompt injection com efeito externo, ação MCP não autorizada, supply-chain, path traversal, command injection e bypass de sandbox ou permissão.

## Security model

O plugin não distribui credenciais do mantenedor. Cada usuário fornece sua própria autenticação Codex e, opcionalmente, sua própria `API_KEY_21ST`. Somente `21st/search` é automaticamente autorizado pela política do Toolkit; custo, quota, instalação/cópia e mutations exigem autorização explícita.

Skills podem conter e executar código local. Pins, hashes e proveniência identificam o conteúdo, mas não garantem que ele seja seguro. A revisão atual encontrou bloqueadores nos snapshots upstream; consulte [Security model](docs/SECURITY-MODEL.md) antes de instalar.

G7-SR1 coloca adapters próprios do FTK na raiz de discovery e mantém snapshots upstream somente em `third_party/upstreams/`. Em G7-SR2D, o runner FTK adiciona `PROJECT_CODE_EXECUTION`, config estrutural, ambiente child-only allowlisted, validação JSON/GLB e state guard no boundary real. Após revalidação do committed HEAD em G7-SR2E e revisão humana, G7S-001 e G7S-002 estão **CLOSED**; G7S-003 e G7S-004 continuam **OPEN** para G7-SR3.

Hooks, Magic MCP, Jpisnice e código oficial do 21st não fazem parte da V1. Fixtures, perfis Codex e autenticação de teste devem ser isolados e descartáveis.

Veja também `docs/ARCHITECTURE.md`, `docs/SECURITY-REMEDIATION-LESSONS.md`, `docs/INSTALLATION.md` e `THIRD_PARTY_NOTICES.md`.
