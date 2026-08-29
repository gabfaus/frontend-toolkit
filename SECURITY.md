# Security Policy

## Supported versions

Antes da primeira release pública, somente o branch de desenvolvimento atual recebe correções. Após `v1.0.0`, a linha `1.x` mais recente será suportada; versões anteriores poderão receber correções críticas conforme risco e viabilidade.

## Reporting a vulnerability

Não inclua secrets, tokens, credenciais, dados pessoais ou detalhes exploráveis em uma issue pública. Use o canal privado de security advisory da futura hospedagem pública. Enquanto esse canal ainda não estiver configurado, contate o mantenedor pelo canal privado associado ao repositório e aguarde confirmação antes de divulgar.

O relatório deve conter impacto, componente afetado, versão, passos mínimos de reprodução e mitigação conhecida. Não envie credenciais reais.

## Security model

- O plugin não contém secrets. `API_KEY_21ST` é referenciada somente pelo nome da variável de ambiente.
- Somente `21st/search` é automaticamente autorizado. Custo, quota, retrieval de código e mutations exigem autorização explícita.
- Shadcn é limitado a consultas read-only nos testes e na configuração recomendada.
- Snapshots externos são gerados apenas dos SHAs pinados, com hashes, licença, NOTICE e proveniência validados.
- Hooks, Magic MCP, Jpisnice e código oficial do 21st não fazem parte da V1.
- Fixtures, perfis Codex e autenticação de teste são isolados e descartáveis.

Veja também `docs/ARCHITECTURE.md`, `docs/INSTALLATION.md` e `THIRD_PARTY_NOTICES.md`.
