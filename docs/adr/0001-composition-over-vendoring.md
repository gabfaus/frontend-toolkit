# ADR 0001 — Composição em vez de vendoring

- Status: proposta para revisão humana
- Data: 2026-08-27

## Contexto

O Frontend Toolkit precisa reunir duas Skills externas, dois MCPs e uma futura Skill de orquestração. Copiar os projetos externos criaria ownership falso, dificultaria atualizações e misturaria obrigações de licença.

## Decisão

Manter as dependências independentes e integrá-las por contratos declarativos, versões pinadas, configuração e testes. O repositório próprio conterá somente a camada de integração e, no futuro, o manifesto do plugin.

O 21st será integrado pelo endpoint MCP atual. O repositório legado `magic-mcp`, inclusive seu proxy de compatibilidade, fica explicitamente excluído.

## Consequências positivas

- origem e licença permanecem claras;
- atualizações são isoladas e reversíveis;
- reduz conflitos entre upstreams;
- facilita testar cada capacidade e removê-la sem reescrever o toolkit.

## Custos

- exige lock/inventário próprios;
- mudanças incompatíveis dos upstreams precisam de adaptadores;
- um plugin único deverá coordenar dependências com modelos de distribuição diferentes;
- serviços MCP remotos não podem ser realmente pinados como código local.

## Revisão

Reavaliar na FTK-05 depois dos testes reais de empacotamento e conflito com o plugin oficial do 21st.

