#!/usr/bin/env bash
#
# install.sh — Instalador do plugin ValorBrain para ZCode.
#
# Uso:
#   ./install.sh                              # interativo (pergunta token se faltar)
#   ./install.sh --token vbm_XXX              # não-interativo, com token
#   VALORBRAIN_MCP_TOKEN=vbm_XXX ./install.sh # via env
#
# Funciona em macOS e Linux. Idempotente (pode rodar várias vezes).
#
set -euo pipefail

# ---------- Defaults ----------
MARKETPLACE_NAME="valor-digital"
PLUGIN_NAME="valorbrain"
PLUGIN_VERSION="0.1.0"
DEFAULT_MCP_URL="https://mcpbrain.valor.digital/mcp"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZCODE_HOME="${HOME}/.zcode/cli"
CACHE_BASE="${ZCODE_HOME}/plugins/cache/${MARKETPLACE_NAME}/${PLUGIN_NAME}/${PLUGIN_VERSION}"
MARKETPLACE_DIR="${ZCODE_HOME}/plugins/marketplaces/${MARKETPLACE_NAME}"
DATA_DIR="${ZCODE_HOME}/plugins/data/${PLUGIN_NAME}@${MARKETPLACE_NAME}"
CONFIG_FILE="${ZCODE_HOME}/config.json"

# ---------- Helpers ----------
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$1"; }
c_bold()  { printf '\033[1m%s\033[0m' "$1"; }

log()  { printf '%s %s\n' "$(c_green '✓')" "$1"; }
warn() { printf '%s %s\n' "$(c_yellow '⚠')" "$1"; }
err()  { printf '%s %s\n' "$(c_red '✗')" "$1" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "'$1' não encontrado. Instale antes de continuar."; exit 1; }
}

json_get() {
  # $1 = file, $2 = jq path. Returns empty if missing/file invalid.
  [ -f "$1" ] || { echo ""; return; }
  jq -r "$2 // empty" "$1" 2>/dev/null || echo ""
}

# ---------- Pre-flight ----------
echo "$(c_bold 'ValorBrain Plugin Installer') — v${PLUGIN_VERSION}"
echo ""

need_cmd jq
need_cmd curl

# ---------- Parse args ----------
INTERACTIVE=true
CLI_TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) CLI_TOKEN="$2"; shift 2; INTERACTIVE=false;;
    --uninstall)
      SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
      if [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then exec "${SCRIPT_DIR}/uninstall.sh"; fi
      err "uninstall.sh não encontrado ao lado de install.sh"; exit 1 ;;
    --help|-h)
      sed -n '2,10p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) err "argumento desconhecido: $1"; exit 1 ;;
  esac
done

# ---------- Resolve token (precedence: --token > env > config.json) ----------
TOKEN="${CLI_TOKEN:-${VALORBRAIN_MCP_TOKEN:-}}"
MCP_URL="${VALORBRAIN_MCP_URL:-$DEFAULT_MCP_URL}"

# Check existing config.json for MCP entry
EXISTING_MCP_URL=""
EXISTING_MCP_TOKEN=""
if [ -f "$CONFIG_FILE" ]; then
  EXISTING_MCP_URL=$(json_get "$CONFIG_FILE" '.mcp.servers.valorbrain.url')
  EXISTING_MCP_RAW=$(json_get "$CONFIG_FILE" '.mcp.servers.valorbrain.headers.Authorization')
  if [ -n "$EXISTING_MCP_RAW" ]; then
    EXISTING_MCP_TOKEN="${EXISTING_MCP_RAW#Bearer }"
  fi
fi

HAS_GLOBAL_MCP=false
[ -n "$EXISTING_MCP_URL" ] && [ -n "$EXISTING_MCP_TOKEN" ] && HAS_GLOBAL_MCP=true

# Resolve final token/url
if [ -z "$TOKEN" ] && [ "$HAS_GLOBAL_MCP" = true ]; then
  TOKEN="$EXISTING_MCP_TOKEN"
  MCP_URL="$EXISTING_MCP_URL"
fi

if [ -z "$TOKEN" ] && [ "$INTERACTIVE" = true ]; then
  echo "Nenhum token encontrado. Obtenha seu token vbm_... no painel do ValorBrain."
  printf "Cole aqui: "
  read -r TOKEN
  [ -z "$TOKEN" ] && { err "Token é obrigatório. Abortando."; exit 1; }
fi

if [ -z "$TOKEN" ]; then
  err "Token obrigatório. Use --token vbm_XXX ou VALORBRAIN_MCP_TOKEN=vbm_XXX ./install.sh"
  exit 1
fi

# ---------- Validate token against MCP (health check) ----------
echo "Validando token contra o MCP ValorBrain..."
# Auth header via temp config file (avoids token in argv; portable across shells)
AUTH_CFG=$(mktemp)
trap 'rm -f "$AUTH_CFG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTH_CFG"
chmod 600 "$AUTH_CFG"
PING_RESP=$(curl -sf -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -K "$AUTH_CFG" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whoami","arguments":{}}}' \
  --connect-timeout 5 --max-time 10 2>/dev/null) || {
  err "Não foi possível conectar ao MCP ($MCP_URL). Verifique URL, token e rede."
  err "Resposta parcial: ${PING_RESP:-<vazia>}"
  exit 1
}

PING_OK=$(echo "$PING_RESP" | jq -r '.result.content[0].text // empty' 2>/dev/null | head -1)
if [ -z "$PING_OK" ]; then
  RPC_ERR=$(echo "$PING_RESP" | jq -r '.error.message // empty' 2>/dev/null)
  err "Token inválido ou erro RPC: ${RPC_ERR:-<desconhecido>}"
  exit 1
fi
log "Token válido. MCP respondeu: $(echo "$PING_OK" | head -1)"
echo ""

# ---------- Step 1: Copy plugin to cache ----------
echo "$(c_bold '[1/5]') Instalando arquivos do plugin..."
mkdir -p "$(dirname "$CACHE_BASE")"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude='.git' --exclude='docs/' --exclude='install.sh' \
    "${SCRIPT_DIR}/" "${CACHE_BASE}/"
else
  # Portable fallback — Windows Git Bash ships no rsync.
  mkdir -p "${CACHE_BASE}"
  cp -r "${SCRIPT_DIR}/." "${CACHE_BASE}/"
  rm -rf "${CACHE_BASE}/.git" "${CACHE_BASE}/docs" "${CACHE_BASE}/install.sh"
fi
chmod +x "${CACHE_BASE}/bin/vbctl" "${CACHE_BASE}/hooks/session-start" \
  "${CACHE_BASE}/hooks/user-prompt-submit" "${CACHE_BASE}/hooks/post-tool-use" \
  "${CACHE_BASE}/hooks/stop" "${CACHE_BASE}/hooks/run-hook.cmd"
log "Plugin copiado para ${CACHE_BASE}"

# ---------- Step 2: Marketplace registry ----------
echo "$(c_bold '[2/5]') Registrando marketplace..."
mkdir -p "$MARKETPLACE_DIR"
# On Windows (Git Bash/MSYS/Cygwin), a raw $HOME-based path is either
# C:\... (single backslashes = invalid JSON escape in a heredoc) or
# /c/... (unresolvable by the native ZCode app). Normalize to a native
# Windows path and let jq handle the JSON escaping by construction.
if command -v cygpath >/dev/null 2>&1 && case "${OSTYPE:-}" in msys*|cygwin*) true;; *) false;; esac; then
  CACHE_BASE_JSON=$(cygpath -w "$CACHE_BASE")
else
  CACHE_BASE_JSON="$CACHE_BASE"
fi
jq -n \
  --arg cache "$CACHE_BASE_JSON" \
  --arg mkt "$MARKETPLACE_NAME" \
  --arg name "$PLUGIN_NAME" \
  --arg ver "$PLUGIN_VERSION" \
  '{name: $mkt,
    plugins: [{cachePath: $cache, name: $name, source: "filesystem", version: $ver}],
    version: 1}' \
  > "${MARKETPLACE_DIR}/marketplace.json"
log "Marketplace registrado"

# ---------- Step 3: MCP config (hybrid logic) ----------
echo "$(c_bold '[3/5]') Configurando MCP..."

if [ "$HAS_GLOBAL_MCP" = true ]; then
  # Já existe MCP global — remover mcpServers do plugin.json pra evitar conflito
  # O vbctl já lê do config.json global.
  warn "MCP já configurado globalmente no config.json — plugin usará esse."
  if jq -e '.mcpServers' "${CACHE_BASE}/.zcode-plugin/plugin.json" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq 'del(.mcpServers) | del(.userConfig.valorbrain_url) | del(.userConfig.valorbrain_token)' \
      "${CACHE_BASE}/.zcode-plugin/plugin.json" > "$tmp" && mv "$tmp" "${CACHE_BASE}/.zcode-plugin/plugin.json"
    log "mcpServers removido do plugin.json (MCP global prevalece)"
  fi
else
  # Não há MCP global — injetar no config.json
  warn "Nenhum MCP global encontrado — injetando mcp.servers.valorbrain no config.json"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
{
  "plugins": { "enabledPlugins": {} },
  "mcp": { "servers": {} }
}
EOF
  fi
  tmp=$(mktemp)
  jq --arg url "$MCP_URL" --arg tok "$TOKEN" \
    '.mcp.servers.valorbrain = {type:"http", url:$url, headers:{Authorization:("Bearer "+$tok)}}' \
    "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  log "MCP injetado no config.json"
fi

# ---------- Step 4: Enable plugin ----------
echo "$(c_bold '[4/5]') Habilitando plugin no config.json..."
ENABLE_KEY="${PLUGIN_NAME}@${MARKETPLACE_NAME}"
tmp=$(mktemp)
jq --arg k "$ENABLE_KEY" \
  '.plugins.enabledPlugins[$k] = true' \
  "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
log "Plugin habilitado: ${ENABLE_KEY}"

# ---------- Step 5: Data dir + config.env ----------
echo "$(c_bold '[5/5]') Criando diretório de dados..."
mkdir -p "$DATA_DIR"
cat > "${DATA_DIR}/config.env" <<'EOF'
# ValorBrain plugin config override (opcional)
# Descomente e preencha para sobrescrever ~/.zcode/cli/config.json:
# VALORBRAIN_MCP_URL=https://mcpbrain.valor.digital/mcp
# VALORBRAIN_MCP_TOKEN=vbm_seu_token_aqui
EOF
chmod 600 "${DATA_DIR}/config.env"
log "Data dir criado: ${DATA_DIR}"

# ---------- Smoke test ----------
echo ""
echo "$(c_bold 'Smoke test')"
echo "${CACHE_BASE}/bin/vbctl ping (primeiras 2 linhas):"
PING=$("${CACHE_BASE}/bin/vbctl" ping 2>/dev/null | head -2) || true
if [ -n "$PING" ]; then
  log "vbctl respondeu:"
  echo "  $PING" | head -2 | sed 's/^/    /'
else
  warn "vbctl não respondeu — verifique a instalação"
fi

# ---------- Done ----------
echo ""
DONE_MSG=$(c_green '✓ Instalação completa.')
echo "$(c_bold "$DONE_MSG")"
echo ""
echo "  Reinicie o ZCode para ativar hooks e skill."
echo "  Para validar: abra nova sessão e verifique se <valorbrain-context> aparece."
echo ""
echo "  Desinstalar: ./install.sh --uninstall  (ou remova manualmente)"
echo "  Docs: README.md"
