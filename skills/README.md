# Skills

A Skill própria `frontend-orchestrator` é desenvolvida repo-localmente em `.agents/skills/frontend-orchestrator/`. Ela permanece separada desta pasta porque `.agents/skills` é a superfície oficial de discovery por projeto já validada.

Durante FTK-02A, Skills externas não são copiadas para esta pasta. Elas permanecem em `external/` e são expostas repo-localmente por junctions ignoradas em `.agents/skills/`.

A distribuição final ainda será decidida na FTK-05. Não copiar a Skill própria para `skills/`, não criar manifesto de plugin e não incorporar os checkouts upstream antes desse gate.
