# Frontend Toolkit — regras do repositório

- Este repositório contém integração, configuração, orquestração, documentação e testes do Frontend Toolkit.
- Não copiar, fundir ou alterar manualmente o código-fonte de dependências externas. Excepcionalmente, Impeccable e img2threejs podem ser materializados somente em artefatos de distribuição/teste por geração automática a partir de upstream e SHA registrados, com integridade validada, LICENSE/NOTICE/proveniência preservados, nenhuma edição manual ou alteração dos checkouts, sem tratá-los como fonte de verdade e com regeneração determinística. Esses snapshots não podem ser commitados na árvore-fonte sem decisão humana futura explícita.
- Não incorporar o antigo `magic-mcp`; usar somente a integração atual do 21st.
- Não instalar dependências nem alterar configuração de usuário sem autorização explícita da etapa correspondente.
- Preferir configuração por projeto durante desenvolvimento e testes.
- Nunca gravar tokens, chaves, cookies ou credenciais no repositório, exemplos, logs ou documentação.
- Toda dependência externa deve ter origem, versão ou commit, licença e procedimento de atualização registrados.
- Hooks devem ser mínimos, auditáveis, locais ao projeto e aprovados explicitamente.
- Não publicar, empacotar, commitar ou fazer push sem autorização humana específica.
- Mudanças em outros repositórios, inclusive Atlas e Atlas Scanner, estão fora de escopo.
