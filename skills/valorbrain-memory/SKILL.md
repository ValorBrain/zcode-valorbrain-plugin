---
name: valorbrain-memory
description: Recall, store, handoff e health da memória persistente ValorBrain. Use quando precisar lembrar contexto de sessões/agentes anteriores, registrar decisões/observações/descobertas, repassar contexto entre sessões, ou manter a saúde do vault de memória.
---

# ValorBrain Memory

Memória persistente compartilhada entre todos os seus agentes (ZCode, Kiro, OpenCode, Devin, Hermes).
Esta skill guia QUANDO usar cada grupo de tools e COMO estruturar boas memórias.

## Quando usar

- Precisar lembrar de algo decidido/descoberto em sessão anterior.
- Após fazer uma mudança que um critério de gravação (abaixo) cobre.
- No fim de uma sessão com trabalho significativo (handoff).
- Para manutenção do vault (periodicamente).

## Workflow 1 — Recall (lembrar)

Antes de responder perguntas conceituais ou retomar trabalho, verifique se já existe contexto.

| Situação | Tool | Exemplo |
|----------|------|---------|
| Pergunta conceitual / "como fazemos X" | `memory_retrieve` | "como lidamos com multi-tenant?" |
| Valor exato, ID, data, chave (busca literal) | `memory_grep` | "qual o valor de `X_API_KEY`?", "mudou entre v1 e v2?" |
| Fato puntual com data | `keyed_facts_as_of` | snapshot de config em data específica |
| Contexto da sessão/prompt atual | `memory_prepare` | (geralmente automático via hook) |
| Orientação rápida no início da sessão | `working_context` | stable facts + decisões recentes em uma chamada |
| Documento similar a um de referência | `find_similar` | "ache docs parecidos com este" |
| Histórico de um documento | `timeline` | "como este decision evoluiu" |
| Documento específico por path/id | `get` / `multi_get` | leitura direta |
| Relação causal | `find_causal_links` | "o que causou este problema?" |

**Boa prática:** prefira `memory_retrieve` (híbrido) pra perguntas abertas. Use `memory_grep` pra buscas exatas (valor, ID, data) — ele devolve só a linha correspondente, custando muito menos token que um trecho inteiro. Use `keyed_facts_as_of` pra fatos versionados (configs, estados). No início de sessão, `working_context` é o atalho mais barato pra se situar.

### Feche o laço de qualidade após o recall

Ao usar uma memória na resposta, declare-a com `memory_used` (passando os docids, ex: `#ab12cd`, ou os caminhos que vieram no recall). As linhas de contexto entregue já trazem o docid — copie-o. Isso faz a memória útil subir no ranking e a irrelevante decair — é o sinal de feedback mais forte que existe. **Regra, não opcional**: sem a declaração, o sinal de qualidade fica cego e a cobertura de uso do tenant não sai do lugar.

## Workflow 2 — Store (registrar)

### Os 7 critérios de gravação

Grave uma memória SE UM OU MAIS destes for verdadeiro:

1. **Decisão arquitetural ou de design** tomada (não apenas implementação direta).
2. **Novo padrão, convenção ou antipattern** descoberto/introduzido.
3. **Fix não-trivial** — bug que custou investigação, não correção óbvia.
4. **Bug recorrente** (já aconteceu antes, provavelmente vai repetir).
5. **Decisão de produto ou trade-off** (o porquê, não só o quê).
6. **Resultado de pesquisa ou spike** (descoberta que vale lembrar amanhã).
7. **Mudança que você provavelmente vai precisar lembrar amanhã.**

Se nenhum critério se aplicar: **NÃO grave.** Silêncio é saudável para o vault.

### Template de boa memória

Chame `mcp__valorbrain__memory_store` com:

- **type**: `decision` | `observation` | `problem` | `milestone` | `handoff` | `lesson` | `note`
- **title**: 5-200 chars, específico e buscável. ❌ "Update no código" → ✅ "Adotar pgvector para vector search no tenant-scoped DB"
- **content** (markdown):

````markdown
## Contexto
[por que isso importa, qual o problema]

## Decisão / Descoberta
[o quê, com racional — não só o resultado]

## Evidência
[arquivo:linha, commit, output de comando, link]
````

- **collection**: agrupe por projeto/tema (ex: `auth`, `infra`, `valorbrain`).
- **tags**: categorias para filtragem.
- **confidence**: 0-1 (default 0.8 pra decisions, 0.6 pra observations).

### Anti-patterns

- ❌ Título vago ("Update", "Fix", "Refactor").
- ❌ Content sem contexto (só o quê, sem porquê).
- ❌ Gravar trivia (`git status`, log de build, output de `ls`).
- ❌ Duplicar memória existente — faça `memory_retrieve` antes de gravar.

### Corrigindo um fato gravado errado

Quando um valor persistido está **errado**, não use `memory_store` para "corrigir" criando outro doc. Use `assert_authority_correction`: ele persiste o valor correto com nível de autoridade, marca os valores anteriores do mesmo `fact_key` como superados (perdedores) e invalida soft os docs em prosa que ainda afirmam o valor antigo. Use `upsert_keyed_fact` apenas para snapshots neutros versionados por data — reserve a correção autoritativa pra quando há um valor "certo" que substitui um "errado".

### Notas efêmeras vs. diário

- **`scratchpad`** — rascunho de raciocínio só desta sessão (não indexado na busca híbrida). Use pra acumular observações intermediárias que você vai consolidar depois; limpe ao fim.
- **`diary_write`** / **`diary_read`** — diário observacional do agente (eventos, decisões, contexto de ambiente). Entradas ficam memorias buscáveis. Use quando quiser registrar algo pra revisão futura fora do fluxo de Store formal.

## Workflow 3 — Handoff (passar adiante)

No fim de uma sessão com trabalho significativo, registre um handoff para que o próximo agente (ou você amanhã) retome sem perda.

**Use `team_handoff`** (preferido — notifica teammates) ou `memory_store` com `type=handoff`.

Conteúdo obrigatório de um bom handoff:
- **O que mudou** (resumo executivo).
- **Arquivos tocados** (paths).
- **Próximos passos** (o que falta fazer).
- **Decisões pendentes** ou riscos.

Exemplo:
```
mcp__valorbrain__team_handoff
  to: "agent"
  summary: "Implementei vbctl CLI (Tasks 1-2 do plan). Próximo: hooks session-start e user-prompt-submit."
  files_changed: ["bin/vbctl"]
  priority: "normal"
```

Quando você **consumir** um handoff (terminou o trabalho, ou é duplicata/resolvido), marque-o com `team_handoff_consume` — evita acúmulo de handoffs stale no briefing.

### Arcos narrativos

Para encadear episódios em torno de um objetivo, use `create_memory_arc` e liste-os com `list_memory_arcs` (filtre por status: `active` | `completed` | `paused`) ou `list_arcs`. Útil pra tracker uma iniciativa de longa duração através de múltiplas sessões.

## Workflow 4 — Health (manutenção)

Periodicamente (ou quando o recall degradar):

- `memory_health` — propostas de limpeza/merge (rode semanal).
- `lifecycle_sweep` (dry_run primeiro) — arquiva docs stale.
- `index_stats` — tamanho do vault, docs precisando embedding.
- `reindex` — se houver docs stale (>0) após mudanças.
- `notifications_check` — alertas/propostas acumuladas.
- `usage_report` — uso medido do tenant (operações por canal/ferramenta/agente, latência p50/p95, série diária). Dimensiona valor entregue e ajuda a planejar capacidade.

### Operações longas (`run_async`)

Tools como `reindex`, `import_docs`, `vault_sync`, `build_graphs`, `lifecycle_sweep` e `export_docs` aceitam `run_async=true` para não segurar a chamada. Quando usar:
- `operation_status` (passe `wait_ms` pra long-poll) — acompanhe progresso e pegue o resultado ao terminar.
- `operation_list` — encontre um handle perdido ou veja se outra instância já tem um reindex rodando.
- `operation_cancel` — pare cooperativamente (o runner para no próximo checkpoint, sem deixar escrita pela metade).

**Princípio:** vault enxuto recall melhor. Inflação degrada. Por isso os critérios de Store são seletivos.

## Mapa completo de tools (68)

| Grupo | Tools |
|-------|-------|
| **Recall** | `memory_retrieve`, `memory_prepare`, `memory_grep`, `working_context`, `find_similar`, `keyed_facts_as_of`, `timeline`, `multi_get`, `get`, `ripple_rag_retrieve`, `memory_evolution_status` |
| **Store** | `memory_store`, `store`, `import_docs`, `upsert_keyed_fact`, `assert_authority_correction`, `diary_write`, `record_lesson`, `memory_pin`, `memory_snooze`, `memory_forget`, `append_entity_card`, `memory_used` |
| **Collab** | `team_message`, `team_handoff`, `team_handoff_consume`, `team_inbox`, `team_notify_human`, `team_briefing`, `team_roster`, `create_memory_arc`, `list_memory_arcs`, `list_arcs`, `list_memory_episodes`, `get_memory_episode`, `profile`, `whoami` |
| **Graph/Health** | `kg_query`, `kg_explain`, `find_causal_links`, `build_graphs`, `memory_health`, `lifecycle_sweep`, `lifecycle_restore`, `lifecycle_status`, `index_stats`, `reindex`, `beads_sync`, `vault_sync`, `list_vaults`, `notifications_check`, `notifications_mark_read`, `feedback_check`, `feedback_submit`, `list_proposals`, `list_lessons`, `export_docs`, `list_entity_cards`, `list_kg_quarantine`, `approve_kg_quarantine`, `reject_kg_quarantine`, `kg_entity_resolve_report`, `usage_report` |
| **Ops/Sessão** | `operation_status`, `operation_list`, `operation_cancel`, `scratchpad`, `diary_read` |
