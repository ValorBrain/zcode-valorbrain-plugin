# ValorBrain ZCode Plugin — Design Spec

**Data:** 2026-07-01
**Status:** Draft — pending user review
**Autor:** Gus (Valor Digital)
**Abordagem:** A — Hooks burros + skill decide (read automático + write seletivo)

---

## 1. Contexto e Motivação

O ValorBrain é a engine de memória persistente da Valor Digital, exposta via MCP
(Microsoft-CHandler Protocol) remoto em `https://mcpbrain.valor.digital/mcp`. Hoje
está integrado ao ZCode apenas como uma entrada manual no `~/.zcode/cli/config.json`:

```json
"mcp": {
  "servers": {
    "valorbrain": {
      "type": "http",
      "url": "https://mcpbrain.valor.digital/mcp",
      "headers": { "Authorization": "Bearer vbm_..." }
    }
  }
}
```

Isso funciona (2.826 documentos indexados, 62 collections, recall funcional), mas
**não é um plugin estruturado**. Falta:

- Workflow codificado — o agente não sabe *quando* ou *como* usar as 31 tools.
- Contexto automático — perfil e briefing de memória não são injetados no início
  da sessão.
- Rastreabilidade — decisões e observações não são capturadas salvo chamada
  explícita.
- Distribuição — não é instalável via marketplace, não versionado.

Este spec formaliza a integração completa como um plugin ZCode.

## 2. Decisões de Design (validadas)

| Decisão | Escolha | Rationale |
|---------|---------|-----------|
| **Escopo** | Plugin completo + hooks automáticos | Máxima integração: estrutura + automação |
| **Automação** | Read automático + write seletivo | Leitura segura é automática; gravação tem ambiguidade, fica com o agente via critérios auditáveis |
| **Distribuição** | Repo git próprio + marketplace novo | Versionamento semver independente, instalável via URL, compartilhável no futuro |
| **Abordagem de write** | Hooks burros + skill decide (A) | Scripts de hook simples; decisão de gravação fica numa skill com critérios claros |

### Não-metas (YAGNI)

- ❌ Heurística de diff nos hooks (Abordagem B) — frágil, falsos-positivos.
- ❌ Gravar tudo em draft (Abordagem C) — infla o vault, degrada recall.
- ❌ CLI bridge em Node — `curl`+`jq` em bash é suficiente e sem dependência.
- ❌ Multi-vault — single-vault mode é adequado pra uso solo atual.

## 3. Arquitetura

```
┌──────────────────────────────────────────────────────────┐
│                    PLUGIN VALORBRAIN                      │
│                                                           │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────┐   │
│  │   hooks/    │   │   skills/    │   │  bin/         │   │
│  │ (eventos)   │   │ (workflows)  │   │ vbctl (CLI)   │   │
│  └──────┬──────┘   └──────┬───────┘   └───────┬───────┘   │
│         │                 │                   │           │
│         │ injeta          │ invoca            │ chamam     │
│         │ contexto        │ via tool          │ via HTTP   │
│         ▼                 ▼                   ▼           │
│  ┌──────────────────────────────────────────────────┐     │
│  │       AGENTE (decide quando gravar)              │     │
│  └────────────────────┬─────────────────────────────┘     │
└───────────────────────┼───────────────────────────────────┘
                        │
        ┌───────────────┴────────────────┐
        │  mcp__valorbrain__* (HTTP)     │  ← já existe
        │  https://mcpbrain.valor.digital│
        └────────────────────────────────┘
```

**Princípio fundamental:** hooks são "burros" — só injetam sinais e dados de
leitura no contexto do agente. A decisão de *gravar* é sempre do agente, guiado
pela skill `valorbrain-memory`. Nenhum hook grava por conta própria.

### Fluxo de dados

1. **Evento dispara** → hook shell executa
2. **Hook lê** via `vbctl` (profile, briefing, prepare) OU injeta lembrete estático
3. **Contexto injetado** no agente via `additionalContext` (padrão SDK)
4. **Agente decide** — se relevante, invoca `mcp__valorbrain__*` (store, etc.)
5. **Skill guia** a decisão com critérios auditáveis

## 4. Peça 1 — `vbctl` (CLI helper)

### Propósito

Bridge bash que permite aos hooks chamarem o MCP remoto sem depender do agente.
Hooks rodam em processo shell isolado — não têm acesso às tools `mcp__valorbrain__*`.

### Implementação

Shell script usando `curl` + `jq`. Sem Node, sem dependências além do que macOS
já tem. Fala MCP StreamableHTTP (JSON-RPC over HTTP, com session-id).

**Fluxo one-shot por chamada:**
1. POST `initialize` → captura `Mcp-Session-Id` do header de resposta
2. POST `tools/call` com o tool name + args → captura resultado
3. (não há teardown explícito — servidor HTTP gerencia sessão)

### Subcomandos

Todos **read-only**, exceto `handoff` (write sancionado explícito).

| Comando | Tool MCP chamado | Argumentos | Uso em |
|---------|------------------|------------|--------|
| `vbctl ping` | `whoami` | — | health-check, debug |
| `vbctl profile` | `profile` | — | SessionStart |
| `vbctl briefing` | `team_briefing` | — | SessionStart |
| `vbctl prepare "<msg>"` | `memory_prepare` | `message` | UserPromptSubmit |
| `vbctl handoff "<resumo>"` | `team_handoff` | `summary` (+ `to`, `priority` opcionais) | Stop (quando agente pede via skill) |

### Configuração

Variáveis de ambiente (lidas dos hooks, que herdam de userConfig):

- `VALORBRAIN_MCP_URL` — endpoint MCP (default: `https://mcpbrain.valor.digital/mcp`)
- `VALORBRAIN_MCP_TOKEN` — bearer token

### Tratamento de erro

`vbctl` **sempre termina 0** quando usado por hooks. Em caso de falha (MCP down,
token inválido, timeout), escreve string vazia ou mensagem mínima em stderr (não
stdout — stdout é o contexto que vai pro agente). **Um hook falho nunca quebra
a sessão do usuário.**

### Exemplo de uso

```bash
# SessionStart hook
PROFILE=$(vbctl profile)
BRIEFING=$(vbctl briefing)
# ambos injetados via additionalContext

# UserPromptSubmit hook
CONTEXT=$(vbctl prepare "$USER_PROMPT")
```

### Formato de saída JSON-RPC

`vbctl` faz o framing manualmente. O MCP StreamableHTTP aceita POST com
`Content-Type: application/json` e responde com JSON direto ou SSE. `vbctl` lida
com ambos: se `content-type` da resposta for `text/event-stream`, parseia as
linhas `data:`; senão, usa o JSON direto.

## 5. Peça 2 — Hooks

Formato segue o padrão Claude Code / ZCode SDK (confirmado via `superpowers/hooks/hooks.json`).
Cada hook é um script shell sob `hooks/`, registrado em `hooks/hooks.json`.

### 5.1 `hooks.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start",
          "async": false
        }]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" user-prompt-submit"
        }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" post-tool-use"
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [{
          "type": "command",
          "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" stop",
          "async": true
        }]
      }
    ]
  }
}
```

### 5.2 `run-hook.cmd`

Dispatcher cross-platform (igual ao do superpowers). Recebe o nome do hook como
`$1`, resolve o script correto sob `hooks/`, executa.

### 5.3 Hook: `session-start`

**Dispara em:** início de sessão, clear, compact.
**Ações:**

1. `vbctl ping` → se falhar, loga em stderr, injeta aviso mínimo, termina.
2. `vbctl profile` → perfil do workspace + identidade.
3. `vbctl briefing` → team briefing (alerts, proposals, prioridade).
4. Concatena perfil + briefing numa seção `<valorbrain-context>` com instrução:
   "Contexto da sua memória persistente. Use quando relevante."

**Custo:** 1x por sessão, 2 chamadas read-only.
**Saída:** JSON com `additionalContext` (formato SDK padrão).

### 5.4 Hook: `user-prompt-submit`

**Dispara em:** cada prompt do usuário.
**Ações:**

1. Lê o prompt do stdin (padrão SDK).
2. `vbctl prepare "<prompt>"` → contexto recuperado (recall híbrido, ranked).
3. Injeta como `<valorbrain-recall>` antes da resposta do agente.

**Toggle:** controlado por `userConfig.auto_prepare` (default: `true`).
**Custo:** por prompt, 1 chamada read. Budget limitado pelo próprio MCP.
**Saída:** JSON com `additionalContext`.

Se `auto_prepare` for `false`, o hook é no-op (não injeta nada, economiza
latência). Útil em máquinas lentas ou sessões onde o recall não agrega.

### 5.5 Hook: `post-tool-use`

**Dispara em:** após `Edit`, `Write`, `MultiEdit` bem-sucedidos.
**Ações:** injeta um **lembrete estático** com os 7 critérios de gravação (sem
chamada ao MCP). Lê metadados do tool via stdin (tool name, sucesso/falha).

**Lembrete injetado:**

```
<valorbrain-write-gate>
Acabou de modificar código via <tool>. Avalie se merece gravação na memória.
Use a skill `valorbrain-memory` e grave SE UM OU MAIS dos critérios abaixo for verdadeiro:
1. Decisão arquitetural ou de design tomada (não apenas implementação direta).
2. Novo padrão, convenção ou antipattern descoberto/introduzido.
3. Fix não-trivial — bug que custou investigação, não correção óbvia.
4. Bug recorrente (já aconteceu antes, provavelmente vai repetir).
5. Decisão de produto ou trade-off (qual o porquê, não só o quê).
6. Resultado de pesquisa ou spike (descoberta que vale lembrar amanhã).
7. Mudança que você provavelmente vai precisar lembrar amanhã.

Se nenhum critério se aplicar, NÃO grave — silêncio é saudável para o vault.
Se aplicável, chame `mcp__valorbrain__memory_store` com type, title e content adequados.
</valorbrain-write-gate>
```

**Toggle:** controlado por `userConfig.write_reminder` (default: `true`).
**Custo:** ~0 (não chama MCP).
**Racional:** a decisão de gravar é do agente; o hook só lembra dos critérios.
Lembrede é estático (não varia por arquivo) pra evitar ruído.

### 5.6 Hook: `stop`

**Dispara em:** agente termina de responder (antes de devolver ao usuário).
**Ações:** injeta lembrete de handoff se houve mudança significativa.

**Lembrete injetado:**

```
<valorbrain-handoff-gate>
Se esta sessão envolveu mudança significativa (feature nova, decisão importante,
debug longo), registre um handoff via `mcp__valorbrain__memory_store` (type=handoff)
ou `team_handoff` antes de finalizar. Inclua: o que mudou, arquivos tocados,
próximos passos. Se foi trabalho trivial, ignore este lembrete.
</valorbrain-handoff-gate>
```

**Async:** `true` — não bloqueia a resposta final.
**Custo:** ~0.

## 6. Peça 3 — Skill `valorbrain-memory`

### Propósito

Codificar os workflows de memória: quando usar cada tool, como estruturar
memórias, critérios de gravação. É o "cérebro" que os hooks referenciam.

### Estrutura do SKILL.md

```
---
name: valorbrain-memory
description: Recall, store, handoff e health da memória persistente ValorBrain.
  Use quando precisar lembrar, registrar, ou repassar contexto entre sessões/agentes.
---

# ValorBrain Memory

## Quando usar
[triggers claros]

## Workflow 1: Recall (lembrar)
[mapa: pergunta conceitual → memory_retrieve; factual → keyed_facts_as_of;
 handoff de sessão anterior → timeline; similaridade → find_similar; etc.]

## Workflow 2: Store (registrar)
[os 7 critérios + template de boa memória: type, title, content, collection, tags]

## Workflow 3: Handoff (passar adiante)
[fim de sessão → team_handoff ou memory_store type=handoff]

## Workflow 4: Health (manutenção)
[memory_health, lifecycle_sweep, reindex quando fazer]
```

### Mapa de tools (31 → 4 grupos)

| Grupo | Tools | Quando |
|-------|-------|--------|
| **Recall** | `memory_retrieve`, `memory_prepare`, `find_similar`, `keyed_facts_as_of`, `timeline`, `multi_get`, `get`, `ripple_rag_retrieve` | Lembrar/consultar |
| **Store** | `memory_store`, `store`, `import_docs`, `upsert_keyed_fact`, `diary_write`, `record_lesson`, `memory_pin`, `memory_snooze`, `memory_forget`, `append_entity_card` | Registrar/modificar |
| **Collab** | `team_message`, `team_handoff`, `team_inbox`, `team_notify_human`, `team_briefing`, `team_roster` | Coordenação multi-agente |
| **Graph/Health** | `kg_query`, `kg_explain`, `find_causal_links`, `build_graphs`, `memory_health`, `memory_evolution_status`, `lifecycle_sweep`, `lifecycle_restore`, `index_stats`, `reindex`, `beads_sync`, `vault_sync`, `notifications_*`, `feedback_*` | Conhecimento estruturado + manutenção |

### Template de boa memória (Store)

```markdown
type: decision | observation | problem | milestone | handoff | lesson | note
title: [5-200 chars, específico, buscável]
content:
  ## Contexto
  [por que isso importa]

  ## Decisão / Descoberta
  [o quê, com racional]

  ## Evidência
  [arquivo:linha, commit, output de comando]
collection: [agrupar por projeto/tema]
tags: [categorias]
```

**Anti-patterns a evitar:**
- Título vago: "Update no código" → ❌; "Adotar pgvector p/ vector search no tenant-scoped DB" → ✅
- Content sem contexto: só o quê, sem porquê → ❌
- Gravar trivia: `git status` output → ❌ (salvo em handoff)

## 7. Peça 4 — Distribuição

### Repositório

Repo git novo: `zcode-valorbrain-plugin` (localmente em
`~/zcode-valorbrain-plugin`, remoto a definir — provável
`github.com/valordigital/zcode-valorbrain-plugin`).

### `marketplace.json` próprio

```json
{
  "name": "valor-digital",
  "owner": {
    "name": "Valor Digital",
    "url": "https://valor.digital"
  },
  "plugins": [
    {
      "name": "valorbrain",
      "source": ".",
      "description": "Memória persistente e conhecimento estruturado para agentes ZCode.",
      "version": "0.1.0"
    }
  ],
  "version": 1
}
```

### Instalação (futura)

```bash
# Adicionar marketplace
zcode plugin marketplace add https://github.com/valordigital/zcode-valorbrain-plugin

# Instalar plugin
zcode plugin install valorbrain@valor-digital
```

Durante o desenvolvimento/teste, instalação local via filesystem path.

### Versionamento

semver independente do servidor valorbrain. O plugin declara compatibilidade no
`README.md` (ex: "requer valorbrain-server >= 2.x"). Quebra de MCP tools = major
bump do plugin.

## 8. Plugin Manifest (`.zcode-plugin/plugin.json`)

```json
{
  "name": "valorbrain",
  "version": "0.1.0",
  "description": "Memória persistente e conhecimento estruturado para agentes ZCode.",
  "author": {
    "name": "Valor Digital",
    "url": "https://valor.digital"
  },
  "license": "MIT",
  "homepage": "https://github.com/valordigital/zcode-valorbrain-plugin",
  "repository": "https://github.com/valordigital/zcode-valorbrain-plugin",
  "skills": "skills",
  "hooks": "hooks",
  "mcpServers": {
    "valorbrain": {
      "type": "http",
      "url": "${user_config.valorbrain_url}",
      "headers": {
        "Authorization": "Bearer ${user_config.valorbrain_token}"
      }
    }
  },
  "userConfig": {
    "valorbrain_url": {
      "type": "string",
      "default": "https://mcpbrain.valor.digital/mcp",
      "description": "URL do servidor MCP ValorBrain."
    },
    "valorbrain_token": {
      "type": "string",
      "secret": true,
      "description": "Bearer token de autenticação (formato vbm_...)."
    },
    "auto_prepare": {
      "type": "boolean",
      "default": true,
      "description": "Injeta recall automático a cada prompt (UserPromptSubmit hook)."
    },
    "write_reminder": {
      "type": "boolean",
      "default": true,
      "description": "Injeta lembrete de gravação após Edit/Write (PostToolUse hook)."
    }
  }
}
```

### Nota sobre o servidor MCP

O `mcpServers` no plugin.json declara o servidor HTTP remoto com credenciais via
`userConfig`. Isso **substitui** a entrada manual atual no `config.json` — após
instalar o plugin, a entrada manual pode ser removida (o plugin assume). Durante
a transição, ambas podem coexistir; o plugin toma precedência por ser mais
específico.

## 9. Estrutura de Arquivos

```
zcode-valorbrain-plugin/
├── .zcode-plugin/
│   └── plugin.json                    # manifesto principal
├── .zcode-plugin-seed.json            # fingerprint/marketplace binding
├── package.json                       # metadados npm-style
├── README.md                          # doc de uso + instalação
├── LICENSE                            # MIT
├── marketplace.json                   # registro do marketplace valor-digital
├── bin/
│   └── vbctl                          # CLI helper (bash + curl + jq)
├── hooks/
│   ├── hooks.json                     # registro dos 4 hooks
│   ├── run-hook.cmd                   # dispatcher cross-platform
│   ├── session-start                  # SessionStart hook
│   ├── user-prompt-submit             # UserPromptSubmit hook
│   ├── post-tool-use                  # PostToolUse hook
│   └── stop                           # Stop hook
├── skills/
│   └── valorbrain-memory/
│       └── SKILL.md                   # workflow codificado
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-07-01-valorbrain-plugin-design.md   # este arquivo
```

## 10. userConfig — Variáveis

| Chave | Tipo | Default | Descrição |
|-------|------|---------|-----------|
| `valorbrain_url` | string | `https://mcpbrain.valor.digital/mcp` | Endpoint MCP |
| `valorbrain_token` | string (secret) | — | Bearer token `vbm_...` |
| `auto_prepare` | boolean | `true` | Toggle do hook UserPromptSubmit |
| `write_reminder` | boolean | `true` | Toggle do hook PostToolUse |

**Resolução de credenciais nos hooks** (ordem de precedência, robusta):

1. `VALORBRAIN_MCP_URL` / `VALORBRAIN_MCP_TOKEN` no ambiente do hook (se o
   runtime do plugin injeta `userConfig` como env — confirmar na implementação).
2. Arquivo de config fallback em `${VALORBRAIN_PLUGIN_DATA}/config.env` (escrito
   na instalação ou manualmente): `key=value` lines, sourced pelo hook.
3. Defaults hardcoded (URL only; token é obrigatório — sem token, hooks viram
   no-op com aviso em stderr).

`vbctl` implementa essa cadeia de resolução internamente, então funciona mesmo
se a injeção de env não acontecer. Isso isola o plugin de assunções sobre o
runtime de hooks do ZCode.

## 11. Riscos e Mitigações

| Risco | Probabilidade | Impacto | Mitigação |
|-------|--------------|---------|-----------|
| **Latência no UserPromptSubmit** degrada UX | Média | Médio | Toggle `auto_prepare`; MCP tem budget interno; hook é async-friendly |
| **Token expira/vaza** | Baixa | Alto | `userConfig` com `secret: true`; doc de rotação; fallback pra env var |
| **Ruído do write-reminder** irrita agente/usuário | Média | Baixo | Critérios estritos (7); toggle `write_reminder`; lembrete é estático e curto |
| **MCP remoto cai** | Baixa | Médio | Hooks degradam gracefully (contexto vazio); `vbctl ping` no SessionStart avisa |
| **Conflito com entrada MCP manual no config.json** | Alta (transição) | Baixo | Plugin toma precedência; doc orienta remover entrada manual pós-install |
| **Sessão MCP não fecha no vbctl** | Média | Baixo | One-shot por chamada; servidor HTTP gerencia expiração; não há leak real |
| **Mudança de schema MCP quebra vbctl** | Baixa | Médio | Compatibilidade documentada no README; testes de smoke no vbctl |
| **Runtime de hooks não injeta `userConfig` como env** | Média | Médio | `vbctl` tem cadeia de fallback (env → `config.env` → default); testar cedo na implementação |

## 12. Fora de Escopo (futuro)

- Multi-vault support (quando houver necessidade real).
- Sync de vault local → remoto (já existe `vault_sync` no MCP, não precisa no plugin).
- UI de visualização do grafo de conhecimento (web app separado).
- Integração com outros agentes (Kiro, OpenCode, Devin) — cada um terá seu
  adaptador, mas o `vbctl` é reutilizável.
- Hooks adicionais (PreToolUse gate, SubagentStop) — adicionar quando houver caso
  de uso claro.

## 13. Critérios de Aceitação

O plugin está completo quando:

1. ✅ `zcode plugin install valorbrain` instala sem erro a partir do repo.
2. ✅ Sessão nova injeta `<valorbrain-context>` (profile + briefing) no SessionStart.
3. ✅ Prompt do usuário injeta `<valorbrain-recall>` quando `auto_prepare=true`.
4. ✅ Após Edit/Write, `<valorbrain-write-gate>` aparece e o agente sabe decidir.
5. ✅ Skill `valorbrain-memory` é listada e invocável via `Skill` tool.
6. ✅ `vbctl ping` retorna identidade fora do agente (health-check funciona).
7. ✅ Com MCP down, sessão funciona normalmente (só sem contexto de memória).
8. ✅ Removendo a entrada manual do `config.json`, o plugin assume o MCP.
9. ✅ Toggles `auto_prepare` e `write_reminder` ligam/desligam hooks conforme config.
10. ✅ README documenta instalação, config, troubleshooting.
