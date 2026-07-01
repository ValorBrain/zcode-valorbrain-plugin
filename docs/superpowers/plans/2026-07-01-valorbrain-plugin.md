# ValorBrain ZCode Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Empacotar a integração ValorBrain como um plugin ZCode completo (vbctl CLI + 4 hooks + 1 skill + marketplace) que substitui a entrada MCP manual no `config.json`.

**Architecture:** Hooks bash "burros" injetam contexto de leitura (profile/briefing/prepare via `vbctl`) e lembretes estáticos (write-gate com 7 critérios). A decisão de gravar fica com o agente, guiado pela skill `valorbrain-memory`. O `vbctl` é um CLI bash (curl+jq) que fala MCP JSON-RPC stateless sobre HTTP.

**Tech Stack:** Bash, curl, jq, MCP StreamableHTTP (JSON-RPC), formato plugin ZCode (`.zcode-plugin/plugin.json` + `hooks.json` + `skills/`).

**Repo:** `~/zcode-valorbrain-plugin/`

**Spec de referência:** `docs/superpowers/specs/2026-07-01-valorbrain-plugin-design.md`

**Descoberta técnica validada (remove complexidade do spec):**
- O MCP valorbrain é **stateless**: `tools/call` funciona direto, sem `initialize`/session-id. O `vbctl` faz POST único por chamada.
- Resposta é sempre JSON: `result.content[0].text` contém o texto.
- O endpoint e token já vivem em `~/.zcode/cli/config.json` (`mcp.servers.valorbrain`) — `vbctl` lê dali, zero config extra.

---

## File Structure

```
~/zcode-valorbrain-plugin/
├── .zcode-plugin/plugin.json          # manifesto: name, skills, hooks, mcpServers, userConfig
├── .zcode-plugin-seed.json            # fingerprint do marketplace
├── package.json                        # metadados npm-style
├── README.md                           # doc de uso + instalação
├── LICENSE                             # MIT
├── marketplace.json                    # registry valor-digital
├── bin/
│   └── vbctl                           # CLI helper (bash + curl + jq)
├── hooks/
│   ├── hooks.json                      # registro dos 4 hooks
│   ├── run-hook.cmd                    # dispatcher polyglot (copia modelo superpowers)
│   ├── session-start                   # SessionStart: profile + briefing
│   ├── user-prompt-submit              # UserPromptSubmit: memory_prepare
│   ├── post-tool-use                   # PostToolUse: lembrete estático de gravação
│   └── stop                            # Stop: lembrete de handoff
├── skills/
│   └── valorbrain-memory/
│       └── SKILL.md                    # workflow codificado (4 workflows + 7 critérios)
└── docs/superpowers/
    ├── specs/2026-07-01-valorbrain-plugin-design.md  # já existe
    └── plans/2026-07-01-valorbrain-plugin.md          # este arquivo
```

**Responsabilidades:**
- `bin/vbctl` — única fonte de comunicação com o MCP. Lê config, monta JSON-RPC, faz curl, extrai `.result.content[0].text`. Subcomandos: ping, profile, briefing, prepare, handoff.
- `hooks/*` — cada hook é shell puro. Lê stdin (se aplicável), chama `vbctl` ou injeta texto estático, emite JSON `{additionalContext}` ou `{}`. Nunca quebra sessão.
- `hooks/run-hook.cmd` — polyglot bash+cmd, copiado do superpowers, delega pro hook nomeado.
- `skills/valorbrain-memory/SKILL.md` — texto markdown. Sem código. Guia o agente em recall/store/handoff/health.
- `.zcode-plugin/plugin.json` — declara tudo ao runtime ZCode.

---

## Task 1: Scaffold do repositório e arquivos base

**Files:**
- Create: `~/zcode-valorbrain-plugin/package.json`
- Create: `~/zcode-valorbrain-plugin/LICENSE`
- Create: `~/zcode-valorbrain-plugin/.gitignore`

- [ ] **Step 1: Inicializar git e criar package.json**

```bash
cd ~/zcode-valorbrain-plugin
git init
```

```json
{
  "$schema": "https://json.schemastore.org/package.json",
  "name": "@valordigital/valorbrain-plugin",
  "version": "0.1.0",
  "private": true,
  "license": "MIT",
  "description": "Memória persistente e conhecimento estruturado para agentes ZCode.",
  "bin": {
    "vbctl": "./bin/vbctl"
  }
}
```

- [ ] **Step 2: Criar LICENSE (MIT)**

```
MIT License

Copyright (c) 2026 Valor Digital

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Criar .gitignore**

```
config.env
*.log
.DS_Store
node_modules/
```

- [ ] **Step 4: Commit inicial**

```bash
cd ~/zcode-valorbrain-plugin
git add -A
git commit -m "chore: scaffold plugin repo"
```

---

## Task 2: `bin/vbctl` — CLI helper (peça central)

**Files:**
- Create: `~/zcode-valorbrain-plugin/bin/vbctl`

Este é o coração do plugin. Todos os hooks dependem dele. Por isso vem primeiro e tem seus próprios testes manuais.

**Convenção de erro do `vbctl`:** sempre `exit 0` quando chamado por hooks. Falhas (sem token, MCP down) → stdout vazio + mensagem em stderr. Exit non-zero só em uso incorreto da CLI (arg faltando).

- [ ] **Step 1: Escrever `bin/vbctl` com resolução de config + função genérica de chamada MCP**

```bash
#!/usr/bin/env bash
# vbctl — CLI helper para o plugin ValorBrain.
# Bridge bash (curl + jq) que fala MCP JSON-RPC stateless sobre HTTP.
# Usado pelos hooks (que rodam em shell isolado, sem acesso às tools do agente).
set -uo pipefail

# ---------- Resolução de configuração (3 níveis de fallback) ----------
ZCODE_CONFIG="${HOME}/.zcode/cli/config.json"

resolve_url() {
  # 1. env var
  if [ -n "${VALORBRAIN_MCP_URL:-}" ]; then printf '%s' "$VALORBRAIN_MCP_URL"; return; fi
  # 2. config.env do plugin
  local ce="${VALORBRAIN_PLUGIN_DATA:-${HOME}/.zcode/cli/plugins/data/valorbrain}/config.env"
  if [ -f "$ce" ] && grep -q '^VALORBRAIN_MCP_URL=' "$ce" 2>/dev/null; then
    source "$ce"; printf '%s' "$VALORBRAIN_MCP_URL"; return
  fi
  # 3. ~/.zcode/cli/config.json (já existe hoje)
  if [ -f "$ZCODE_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    local u; u=$(jq -r '.mcp.servers.valorbrain.url // empty' "$ZCODE_CONFIG" 2>/dev/null)
    if [ -n "$u" ]; then printf '%s' "$u"; return; fi
  fi
  # 4. default
  printf '%s' "https://mcpbrain.valor.digital/mcp"
}

resolve_token() {
  if [ -n "${VALORBRAIN_MCP_TOKEN:-}" ]; then printf '%s' "$VALORBRAIN_MCP_TOKEN"; return; fi
  local ce="${VALORBRAIN_PLUGIN_DATA:-${HOME}/.zcode/cli/plugins/data/valorbrain}/config.env"
  if [ -f "$ce" ] && grep -q '^VALORBRAIN_MCP_TOKEN=' "$ce" 2>/dev/null; then
    source "$ce"; printf '%s' "$VALORBRAIN_MCP_TOKEN"; return
  fi
  if [ -f "$ZCODE_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    local t; t=$(jq -r '.mcp.servers.valorbrain.headers.Authorization // empty' "$ZCODE_CONFIG" 2>/dev/null | sed 's/^Bearer //')
    if [ -n "$t" ]; then printf '%s' "$t"; return; fi
  fi
  return 1
}

# ---------- Chamada MCP genérica (stateless, single POST) ----------
# $1 = tool name, $2 = JSON arguments string
mcp_call() {
  local tool="$1" args="${2:-{\}}"
  local url token
  url=$(resolve_url) || { echo "vbctl: no URL resolved" >&2; return 1; }
  token=$(resolve_token) || { echo "vbctl: no token resolved (set VALORBRAIN_MCP_TOKEN or configure ~/.zcode/cli/config.json)" >&2; return 1; }

  local payload
  payload=$(jq -nc --arg t "$tool" --argjson a "$args" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}')

  local resp
  resp=$(curl -sf -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Authorization: Bearer $token" \
    -d "$payload" --max-time 8 2>/dev/null) || { echo "vbctl: MCP request failed (tool=$tool)" >&2; return 1; }

  # Extrai .result.content[0].text ; se erro RPC, loga e falha
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "vbctl: RPC error: $(echo "$resp" | jq -rc '.error.message')" >&2
    return 1
  fi
  echo "$resp" | jq -r '.result.content[0].text // empty'
}

# ---------- JSON escape para injection-safe args ----------
json_str() { printf '%s' "$1" | jq -ncR .; }

# ---------- Subcomandos ----------
cmd_ping() {
  mcp_call "whoami" '{}' || return 1
}

cmd_profile() {
  mcp_call "profile" '{}' || return 1
}

cmd_briefing() {
  mcp_call "team_briefing" '{}' || return 1
}

cmd_prepare() {
  [ -z "${1:-}" ] && { echo "usage: vbctl prepare \"<message>\"" >&2; return 2; }
  local msg; msg=$(json_str "$1")
  mcp_call "memory_prepare" "{\"message\":$msg}" || return 1
}

cmd_handoff() {
  [ -z "${1:-}" ] && { echo "usage: vbctl handoff \"<summary>\" [to]" >&2; return 2; }
  local msg to; msg=$(json_str "$1"); to=$(json_str "${2:-agent}")
  mcp_call "team_handoff" "{\"summary\":$msg,\"to\":$to}" || return 1
}

# ---------- Usage ----------
usage() {
  cat >&2 <<EOF
vbctl — ValorBrain MCP bridge (plugin helper)

Usage: vbctl <command> [args]
  ping                  Health-check (whoami)
  profile               Workspace profile (SessionStart)
  briefing              Team briefing (SessionStart)
  prepare "<msg>"       Recall context for a message (UserPromptSubmit)
  handoff "<summary>" [to]  Register session handoff (Stop)

Config (ordem de precedência):
  1. VALORBRAIN_MCP_URL / VALORBRAIN_MCP_TOKEN (env)
  2. \$VALORBRAIN_PLUGIN_DATA/config.env
  3. ~/.zcode/cli/config.json (mcp.servers.valorbrain)
EOF
}

# ---------- Dispatch ----------
case "${1:-}" in
  ping)     cmd_ping ;;
  profile)  cmd_profile ;;
  briefing) cmd_briefing ;;
  prepare)  shift; cmd_prepare "$@" ;;
  handoff)  shift; cmd_handoff "$@" ;;
  *)        usage; exit 2 ;;
esac
```

- [ ] **Step 2: Tornar executável**

```bash
chmod +x ~/zcode-valorbrain-plugin/bin/vbctl
```

- [ ] **Step 3: Smoke test — ping (deve retornar o profile do Gus)**

Run: `~/zcode-valorbrain-plugin/bin/vbctl ping`
Expected: texto começando com `## User` contendo "Gustavo (Gus)".

- [ ] **Step 4: Smoke test — profile**

Run: `~/zcode-valorbrain-plugin/bin/vbctl profile | head -c 200`
Expected: JSON ou texto com workspace info.

- [ ] **Step 5: Smoke test — prepare**

Run: `~/zcode-valorbrain-plugin/bin/vbctl prepare "teste de recall" | head -c 300`
Expected: contexto recuperado (pode ser longo).

- [ ] **Step 6: Smoke test — falha graceful (token inválido)**

Run: `VALORBRAIN_MCP_TOKEN=invalid ~/zcode-valorbrain-plugin/bin/vbctl ping`
Expected: stderr com mensagem de erro, stdout vazio, **exit 0** (não 1 — hooks não devem quebrar).

> Nota: o `mcp_call` retorna 1 em falha, mas o dispatch `case` propaga. Vamos garantir exit 0 no final dos hooks, não no vbctl. O vbctl pode retornar non-zero pra uso em scripts de diagnóstico. **Os hooks ignoram o exit code do vbctl.**

- [ ] **Step 7: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add bin/vbctl
git commit -m "feat: add vbctl CLI helper for MCP bridge"
```

---

## Task 3: Hooks — `run-hook.cmd` dispatcher

**Files:**
- Create: `~/zcode-valorbrain-plugin/hooks/run-hook.cmd`

Cópia adaptada do polyglot do superpowers (que é o formato confirmado do ZCode).

- [ ] **Step 1: Criar `hooks/run-hook.cmd` (polyglot bash+cmd)**

Conteúdo idêntico ao do superpowers (`/Users/iucksh/.zcode/cli/plugins/cache/zcode-plugins-official/superpowers/5.1.0/hooks/run-hook.cmd`) — é um polyglot genérico que delega pro script nomeado. Copiar literalmente; não precisa adaptação.

```bash
cp /Users/iucksh/.zcode/cli/plugins/cache/zcode-plugins-official/superpowers/5.1.0/hooks/run-hook.cmd \
   ~/zcode-valorbrain-plugin/hooks/run-hook.cmd
chmod +x ~/zcode-valorbrain-plugin/hooks/run-hook.cmd
```

- [ ] **Step 2: Verificar que copiou corretamente**

Run: `head -5 ~/zcode-valorbrain-plugin/hooks/run-hook.cmd`
Expected: `: << 'CMDBLOCK'` na linha 1.

- [ ] **Step 3: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add hooks/run-hook.cmd
git commit -m "feat: add polyglot hook dispatcher"
```

---

## Task 4: Hook `session-start`

**Files:**
- Create: `~/zcode-valorbrain-plugin/hooks/session-start`

**Evento:** `SessionStart` (startup|clear|compact). Injeta `<valorbrain-context>` com profile + briefing.

**Formato de saída do hook:** JSON em stdout. O ZCode lê `additionalContext` (formato SDK padrão, confirmado no session-start do superpowers). Hooks emitem:

```json
{ "additionalContext": "<conteúdo>" }
```

- [ ] **Step 1: Escrever `hooks/session-start`**

```bash
#!/usr/bin/env bash
# SessionStart hook: injeta profile + briefing do ValorBrain no contexto da sessão.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VBCTL="${PLUGIN_ROOT}/bin/vbctl"

# Escape JSON string (rápido, via jq se disponível, senão fallback sed)
escape_for_json() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -ncR .
  else
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
  fi
}

# Coleta profile + briefing (falhas → string vazia, sessão não quebra)
PROFILE="$("$VBCTL" ping 2>/dev/null || true)"
BRIEFING="$("$VBCTL" briefing 2>/dev/null || true)"

# Se ambos vazios, MCP indisponível — injeta aviso mínimo
if [ -z "$PROFILE" ] && [ -z "$BRIEFING" ]; then
  CONTEXT="<valorbrain-context>\nValorBrain MCP indisponível nesta sessão. Memória persistente offline.\n</valorbrain-context>"
else
  CONTEXT="<valorbrain-context>\nMemória persistente ValorBrain ativa. Use quando relevante; não cite explicitamente ao usuário.\n\n## Perfil\n${PROFILE}\n\n## Briefing\n${BRIEFING}\n</valorbrain-context>"
fi

CONTEXT_ESC=$(escape_for_json "$CONTEXT")
printf '{\n  "additionalContext": %s\n}\n' "$CONTEXT_ESC"
exit 0
```

- [ ] **Step 2: Tornar executável**

```bash
chmod +x ~/zcode-valorbrain-plugin/hooks/session-start
```

- [ ] **Step 3: Smoke test rodando direto**

Run: `~/zcode-valorbrain-plugin/hooks/session-start`
Expected: JSON válido com `additionalContext` contendo "Gustavo" e briefing.

- [ ] **Step 4: Validar que o JSON é parseable**

Run: `~/zcode-valorbrain-plugin/hooks/session-start | jq .additionalContext -r | head -c 200`
Expected: texto do contexto sem erro de parse.

- [ ] **Step 5: Teste de falha graceful (MCP down simulado)**

Run: `VALORBRAIN_MCP_URL=http://127.0.0.1:1/mcp ~/zcode-valorbrain-plugin/hooks/session-start | jq .additionalContext -r`
Expected: "ValorBrain MCP indisponível nesta sessão." (não erro, não crash).

- [ ] **Step 6: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add hooks/session-start
git commit -m "feat: add SessionStart hook (profile + briefing injection)"
```

---

## Task 5: Hook `user-prompt-submit`

**Files:**
- Create: `~/zcode-valorbrain-plugin/hooks/user-prompt-submit`

**Evento:** `UserPromptSubmit`. Lê o prompt do stdin (padrão Claude Code SDK: JSON com `.prompt`), chama `vbctl prepare`, injeta `<valorbrain-recall>`.

**Toggle:** respeita `userConfig.auto_prepare` via env var `VALORBRAIN_AUTO_PREPARE`. Se `false`, no-op.

- [ ] **Step 1: Escrever `hooks/user-prompt-submit`**

```bash
#!/usr/bin/env bash
# UserPromptSubmit hook: injeta recall de memória contextual para cada prompt.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VBCTL="${PLUGIN_ROOT}/bin/vbctl"

# Toggle via userConfig (env var injetada pelo runtime, se disponível)
AUTO_PREPARE="${VALORBRAIN_AUTO_PREPARE:-true}"
if [ "$AUTO_PREPARE" = "false" ]; then
  printf '{}\n'; exit 0
fi

escape_for_json() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -ncR .
  else
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
  fi
}

# Lê stdin: JSON {"prompt": "..."} (padrão Claude Code SDK)
INPUT=$(cat)
PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
fi
# Fallback: se não veio JSON ou sem jq, usa stdin cru
[ -z "$PROMPT" ] && PROMPT="$INPUT"

[ -z "$PROMPT" ] && { printf '{}\n'; exit 0; }

# Recall via vbctl (falha → vazio, não quebra)
RECALL="$("$VBCTL" prepare "$PROMPT" 2>/dev/null || true)"

if [ -z "$RECALL" ]; then
  printf '{}\n'; exit 0
fi

CONTEXT="<valorbrain-recall>\nContexto recuperado da memória para este prompt. Use se relevante.\n\n${RECALL}\n</valorbrain-recall>"
CONTEXT_ESC=$(escape_for_json "$CONTEXT")
printf '{\n  "additionalContext": %s\n}\n' "$CONTEXT_ESC"
exit 0
```

- [ ] **Step 2: Tornar executável**

```bash
chmod +x ~/zcode-valorbrain-plugin/hooks/user-prompt-submit
```

- [ ] **Step 3: Smoke test com prompt via stdin**

Run: `echo '{"prompt":"como funciona o auth do projeto?"}' | ~/zcode-valorbrain-plugin/hooks/user-prompt-submit | jq .additionalContext -r | head -c 300`
Expected: `<valorbrain-recall>` com contexto recuperado.

- [ ] **Step 4: Teste do toggle off**

Run: `VALORBRAIN_AUTO_PREPARE=false echo '{"prompt":"x"}' | VALORBRAIN_AUTO_PREPARE=false ~/zcode-valorbrain-plugin/hooks/user-prompt-submit`
Expected: `{}` (no-op).

- [ ] **Step 5: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add hooks/user-prompt-submit
git commit -m "feat: add UserPromptSubmit hook (auto recall)"
```

---

## Task 6: Hook `post-tool-use`

**Files:**
- Create: `~/zcode-valorbrain-plugin/hooks/post-tool-use`

**Evento:** `PostToolUse` (Edit|Write|MultiEdit). **Não chama MCP.** Injeta lembrete estático com os 7 critérios de gravação. Toggle via `VALORBRAIN_WRITE_REMINDER`.

- [ ] **Step 1: Escrever `hooks/post-tool-use`**

```bash
#!/usr/bin/env bash
# PostToolUse hook: injeta lembrete de gravação seletiva após Edit/Write.
# Não chama MCP — é um gate estático. A decisão de gravar é do agente (via skill).
set -uo pipefail

WRITE_REMINDER="${VALORBRAIN_WRITE_REMINDER:-true}"
if [ "$WRITE_REMINDER" = "false" ]; then
  printf '{}\n'; exit 0
fi

# Lê stdin para extrair tool_name (opcional, só pro placeholder)
INPUT=$(cat)
TOOL="Edit"
if command -v jq >/dev/null 2>&1; then
  T=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  [ -n "$T" ] && TOOL="$T"
fi

escape_for_json() {
  if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -ncR .
  else
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; printf '"%s"' "$s"
  fi
}

CONTEXT="<valorbrain-write-gate>
Acabou de modificar código via ${TOOL}. Avalie se merece gravação na memória persistente.
Use a skill \`valorbrain-memory\` e grave SE UM OU MAIS destes critérios for verdadeiro:
1. Decisão arquitetural ou de design tomada (não apenas implementação direta).
2. Novo padrão, convenção ou antipattern descoberto/introduzido.
3. Fix não-trivial — bug que custou investigação, não correção óbvia.
4. Bug recorrente (já aconteceu antes, provavelmente vai repetir).
5. Decisão de produto ou trade-off (o porquê, não só o quê).
6. Resultado de pesquisa ou spike (descoberta que vale lembrar amanhã).
7. Mudança que você provavelmente vai precisar lembrar amanhã.

Se nenhum critério se aplicar, NÃO grave — silêncio é saudável para o vault.
Se aplicável, chame \`mcp__valorbrain__memory_store\` com type, title e content adequados.
</valorbrain-write-gate>"

CONTEXT_ESC=$(escape_for_json "$CONTEXT")
printf '{\n  "additionalContext": %s\n}\n' "$CONTEXT_ESC"
exit 0
```

- [ ] **Step 2: Tornar executável**

```bash
chmod +x ~/zcode-valorbrain-plugin/hooks/post-tool-use
```

- [ ] **Step 3: Smoke test**

Run: `echo '{"tool_name":"Write"}' | ~/zcode-valorbrain-plugin/hooks/post-tool-use | jq .additionalContext -r | head -5`
Expected: `<valorbrain-write-gate>` com os 7 critérios.

- [ ] **Step 4: Teste toggle off**

Run: `echo '{}' | VALORBRAIN_WRITE_REMINDER=false ~/zcode-valorbrain-plugin/hooks/post-tool-use`
Expected: `{}`.

- [ ] **Step 5: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add hooks/post-tool-use
git commit -m "feat: add PostToolUse write-gate hook (7 criteria reminder)"
```

---

## Task 7: Hook `stop`

**Files:**
- Create: `~/zcode-valorbrain-plugin/hooks/stop`

**Evento:** `Stop`. Injeta lembrete de handoff. Não chama MCP.

- [ ] **Step 1: Escrever `hooks/stop`**

```bash
#!/usr/bin/env bash
# Stop hook: lembrete de handoff no fim da sessão/resposta.
set -uo pipefail

escape_for_json() {
  if command -v jq >/dev/null 2>&1; then printf '%s' "$1" | jq -ncR .
  else
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"; printf '"%s"' "$s"
  fi
}

CONTEXT="<valorbrain-handoff-gate>
Se esta sessão envolveu mudança significativa (feature nova, decisão importante, debug longo),
registre um handoff via \`mcp__valorbrain__memory_store\` (type=handoff) ou \`mcp__valorbrain__team_handoff\`
antes de finalizar. Inclua: o que mudou, arquivos tocados, próximos passos.
Se foi trabalho trivial, ignore este lembrete.
</valorbrain-handoff-gate>"

CONTEXT_ESC=$(escape_for_json "$CONTEXT")
printf '{\n  "additionalContext": %s\n}\n' "$CONTEXT_ESC"
exit 0
```

- [ ] **Step 2: Tornar executável e testar**

```bash
chmod +x ~/zcode-valorbrain-plugin/hooks/stop
~/zcode-valorbrain-plugin/hooks/stop | jq .additionalContext -r | head -3
```
Expected: `<valorbrain-handoff-gate>`.

- [ ] **Step 3: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add hooks/stop
git commit -m "feat: add Stop hook (handoff reminder)"
```

---

## Task 8: `hooks/hooks.json` — registro dos 4 hooks

**Files:**
- Create: `~/zcode-valorbrain-plugin/hooks/hooks.json`

- [ ] **Step 1: Escrever `hooks/hooks.json`**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start",
            "async": false
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" user-prompt-submit"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" post-tool-use"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" stop",
            "async": true
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validar JSON**

Run: `jq . ~/zcode-valorbrain-plugin/hooks/hooks.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add hooks/hooks.json
git commit -m "feat: register all 4 hooks"
```

---

## Task 9: Skill `valorbrain-memory`

**Files:**
- Create: `~/zcode-valorbrain-plugin/skills/valorbrain-memory/SKILL.md`

- [ ] **Step 1: Escrever SKILL.md**

```markdown
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
| Fato puntual com data | `keyed_facts_as_of` | snapshot de config em data específica |
| Contexto da sessão/prompt atual | `memory_prepare` | (geralmente automático via hook) |
| Documento similar a um de referência | `find_similar` | "ache docs parecidos com este" |
| Histórico de um documento | `timeline` | "como este decision evoluiu" |
| Documento específico por path/id | `get` / `multi_get` | leitura direta |
| Relação causal | `find_causal_links` | "o que causou este problema?" |

**Boa prática:** prefira `memory_retrieve` (híbrido) pra perguntas abertas. Use `keyed_facts_as_of` pra fatos versionados (configs, estados).

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

```markdown
## Contexto
[por que isso importa, qual o problema]

## Decisão / Descoberta
[o quê, com racional — não só o resultado]

## Evidência
[arquivo:linha, commit, output de comando, link]
```

- **collection**: agrupe por projeto/tema (ex: `auth`, `infra`, `valorbrain`).
- **tags**: categorias para filtragem.
- **confidence**: 0-1 (default 0.8 pra decisions, 0.6 pra observations).

### Anti-patterns

- ❌ Título vago ("Update", "Fix", "Refactor").
- ❌ Content sem contexto (só o quê, sem porquê).
- ❌ Gravar trivia (`git status`, log de build, output de `ls`).
- ❌ Duplicar memória existente — faça `memory_retrieve` antes de gravar.

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

## Workflow 4 — Health (manutenção)

Periodicamente (ou quando o recall degradar):

- `memory_health` — propostas de limpeza/merge (rode semanal).
- `lifecycle_sweep` (dry_run primeiro) — arquiva docs stale.
- `index_stats` — tamanho do vault, docs precisando embedding.
- `reindex` — se houver docs stale (>0) após mudanças.
- `notifications_check` — alertas/propostas acumuladas.

**Princípio:** vault enxuto recall melhor. Inflação degrada. Por isso os critérios de Store são seletivos.

## Mapa completo de tools (31)

| Grupo | Tools |
|-------|-------|
| **Recall** | `memory_retrieve`, `memory_prepare`, `find_similar`, `keyed_facts_as_of`, `timeline`, `multi_get`, `get`, `ripple_rag_retrieve`, `memory_evolution_status` |
| **Store** | `memory_store`, `store`, `import_docs`, `upsert_keyed_fact`, `diary_write`, `record_lesson`, `memory_pin`, `memory_snooze`, `memory_forget`, `append_entity_card` |
| **Collab** | `team_message`, `team_handoff`, `team_inbox`, `team_notify_human`, `team_briefing`, `team_roster`, `create_memory_arc`, `list_memory_arcs`, `list_memory_episodes`, `get_memory_episode`, `profile`, `whoami` |
| **Graph/Health** | `kg_query`, `kg_explain`, `find_causal_links`, `build_graphs`, `memory_health`, `lifecycle_sweep`, `lifecycle_restore`, `lifecycle_status`, `index_stats`, `reindex`, `beads_sync`, `vault_sync`, `list_vaults`, `notifications_check`, `notifications_mark_read`, `feedback_check`, `feedback_submit`, `list_proposals`, `list_lessons`, `export_docs`, `list_entity_cards`, `list_kg_quarantine`, `approve_kg_quarantine`, `reject_kg_quarantine`, `kg_entity_resolve_report` |
```

- [ ] **Step 2: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add skills/valorbrain-memory/SKILL.md
git commit -m "feat: add valorbrain-memory skill (4 workflows + 7 criteria)"
```

---

## Task 10: Plugin manifest `.zcode-plugin/plugin.json`

**Files:**
- Create: `~/zcode-valorbrain-plugin/.zcode-plugin/plugin.json`

- [ ] **Step 1: Criar diretório e escrever plugin.json**

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

- [ ] **Step 2: Validar JSON**

Run: `jq . ~/zcode-valorbrain-plugin/.zcode-plugin/plugin.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add .zcode-plugin/plugin.json
git commit -m "feat: add plugin manifest"
```

---

## Task 11: Marketplace e seed

**Files:**
- Create: `~/zcode-valorbrain-plugin/marketplace.json`
- Create: `~/zcode-valorbrain-plugin/.zcode-plugin-seed.json`

- [ ] **Step 1: Escrever `marketplace.json`**

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

- [ ] **Step 2: Escrever `.zcode-plugin-seed.json`**

O hash é computado pelo runtime do ZCode na instalação. Para o seed inicial, usamos um placeholder que o runtime substitui.

```json
{
  "hash": "",
  "marketplace": "valor-digital",
  "plugin": "valorbrain",
  "pluginVersion": "0.1.0",
  "source": "filesystem",
  "version": 1
}
```

- [ ] **Step 3: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add marketplace.json .zcode-plugin-seed.json
git commit -m "feat: add marketplace registry and seed"
```

---

## Task 12: README

**Files:**
- Create: `~/zcode-valorbrain-plugin/README.md`

- [ ] **Step 1: Escrever README.md**

````markdown
# ValorBrain ZCode Plugin

Memória persistente e conhecimento estruturado para agentes ZCode. Integra o [ValorBrain](https://valor.digital) via MCP, com hooks automáticos de contexto e skill de workflow.

## O que faz

- **SessionStart:** injeta perfil + briefing do workspace automaticamente.
- **UserPromptSubmit:** recupera contexto relevante da memória para cada prompt (toggle).
- **PostToolUse:** lembra o agente de gravar decisões/fixes não-triviais (7 critérios, toggle).
- **Stop:** lembra de registrar handoff em sessões significativas.
- **Skill `valorbrain-memory`:** guia recall/store/handoff/health com mapas das 31 tools.

A decisão de **gravar** é sempre do agente — hooks só injetam lembretes. Leitura é automática.

## Instalação

### Via marketplace (quando publicado)

```bash
zcode plugin marketplace add https://github.com/valordigital/zcode-valorbrain-plugin
zcode plugin install valorbrain@valor-digital
```

### Local (desenvolvimento)

Coloque este diretório no cache de plugins do ZCode ou referencie via filesystem.

## Configuração

O plugin lê credenciais nesta ordem:

1. **`userConfig`** do plugin (definido ao instalar):
   - `valorbrain_url` — endpoint MCP (default: `https://mcpbrain.valor.digital/mcp`)
   - `valorbrain_token` — bearer token `vbm_...` (secret)
   - `auto_prepare` — toggle do recall por prompt (default: `true`)
   - `write_reminder` — toggle do write-gate (default: `true`)
2. **Env vars:** `VALORBRAIN_MCP_URL`, `VALORBRAIN_MCP_TOKEN`
3. **`~/.zcode/cli/config.json`** (`mcp.servers.valorbrain`) — compatibilidade retroativa

### Rotação de token

Gere um novo token no painel do ValorBrain, atualize `valorbrain_token` no userConfig (ou env var). Tokens antigos devem ser revogados.

## Arquitetura

```
hooks/ (eventos bash) → bin/vbctl (bridge curl+jq) → MCP remoto (HTTP)
                                  ↑
skills/valorbrain-memory guia o agente (invoca mcp__valorbrain__*)
```

Hooks são "burros": injetam contexto e lembretes, nunca gravam sozinhos.

## Troubleshooting

| Símbils | Causa | Solução |
|---------|-------|---------|
| `ValorBrain MCP indisponível` no SessionStart | MCP down ou sem token | Verifique `valorbrain_token` e conectividade |
| Sem `<valorbrain-recall>` nos prompts | `auto_prepare=false` | Habilite no userConfig |
| `vbctl: MCP request failed` | rede/auth | rode `bin/vbctl ping` para diagnosticar |

## Desenvolvimento

```bash
# Testar vbctl
./bin/vbctl ping
./bin/vbctl prepare "teste"

# Testar hooks isoladamente
echo '{"prompt":"x"}' | ./hooks/user-prompt-submit
./hooks/session-start
```

## Licença

MIT © Valor Digital
````

- [ ] **Step 2: Commit**

```bash
cd ~/zcode-valorbrain-plugin
git add README.md
git commit -m "docs: add README"
```

---

## Task 13: Teste de integração end-to-end

**Files:** nenhum (validação manual)

- [ ] **Step 1: Validar todos os hooks individualmente**

```bash
cd ~/zcode-valorbrain-plugin
echo "--- session-start ---"; ./hooks/session-start | jq .additionalContext -r | head -3
echo "--- user-prompt-submit ---"; echo '{"prompt":"teste e2e"}' | ./hooks/user-prompt-submit | jq .additionalContext -r | head -3
echo "--- post-tool-use ---"; echo '{"tool_name":"Edit"}' | ./hooks/post-tool-use | jq .additionalContext -r | head -3
echo "--- stop ---"; ./hooks/stop | jq .additionalContext -r | head -3
```

Expected: cada um emite JSON válido com `additionalContext` não-vazio.

- [ ] **Step 2: Validar vbctl em todos os subcomandos**

```bash
./bin/vbctl ping | head -c 100; echo
./bin/vbctl profile | head -c 100; echo
./bin/vbctl briefing | head -c 100; echo
./bin/vbctl prepare "e2e test" | head -c 100; echo
```

Expected: output não-vazio de cada um.

- [ ] **Step 3: Validar falha graceful**

```bash
VALORBRAIN_MCP_URL=http://127.0.0.1:1/mcp ./hooks/session-start | jq .additionalContext -r
```

Expected: "ValorBrain MCP indisponível nesta sessão." (não crash).

- [ ] **Step 4: Validar toggles**

```bash
VALORBRAIN_AUTO_PREPARE=false bash -c 'echo "{\"prompt\":\"x\"}" | ./hooks/user-prompt-submit'
VALORBRAIN_WRITE_REMINDER=false bash -c 'echo "{}" | ./hooks/post-tool-use'
```

Expected: `{}` em ambos.

- [ ] **Step 5: Validar estrutura de arquivos final**

Run: `find ~/zcode-valorbrain-plugin -type f -not -path '*/.git/*' | sort`
Expected: todos os arquivos da estrutura da spec presentes.

- [ ] **Step 6: Commit final (tag)**

```bash
cd ~/zcode-valorbrain-plugin
git add -A
git commit -m "test: validate e2e integration" --allow-empty
git tag v0.1.0
```

---

## Self-Review do Plano

**1. Spec coverage (spec → task):**
- Seção 4 (vbctl): Task 2 ✅
- Seção 5.1-5.2 (hooks.json + run-hook.cmd): Task 8, Task 3 ✅
- Seção 5.3 (session-start): Task 4 ✅
- Seção 5.4 (user-prompt-submit): Task 5 ✅
- Seção 5.5 (post-tool-use + 7 critérios): Task 6 ✅
- Seção 5.6 (stop): Task 7 ✅
- Seção 6 (skill): Task 9 ✅
- Seção 7 (distribuição/marketplace): Task 11 ✅
- Seção 8 (plugin.json): Task 10 ✅
- Seção 9 (estrutura): Tasks 1-12 ✅
- Seção 10 (userConfig): Task 10 ✅
- Seção 13 (critérios de aceitação): Task 13 ✅

**2. Placeholder scan:** nenhum TBD/TODO. Cada step tem código completo ou comando exato.

**3. Type consistency:** `vbctl` subcomandos (ping/profile/briefing/prepare/handoff) consistentes entre Tasks 2, 4, 5. Hooks emitem `additionalContext` consistentemente. userConfig keys (`valorbrain_url`, `valorbrain_token`, `auto_prepare`, `write_reminder`) consistentes entre Tasks 10, 5, 6.

**Sem lacunas. Plano pronto.**
