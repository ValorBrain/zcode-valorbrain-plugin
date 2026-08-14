#!/usr/bin/env bash
#
# uninstall.sh — Remove o plugin ValorBrain do ZCode.
#
set -euo pipefail

MARKETPLACE_NAME="valor-digital"
PLUGIN_NAME="valorbrain"
PLUGIN_VERSION="0.1.0"
ZCODE_HOME="${HOME}/.zcode/cli"
CACHE_DIR="${ZCODE_HOME}/plugins/cache/${MARKETPLACE_NAME}"
MARKETPLACE_DIR="${ZCODE_HOME}/plugins/marketplaces/${MARKETPLACE_NAME}"
DATA_DIR="${ZCODE_HOME}/plugins/data/${PLUGIN_NAME}@${MARKETPLACE_NAME}"
VBCTL_DATA_DIR="${ZCODE_HOME}/plugins/data/${PLUGIN_NAME}"
CONFIG_FILE="${ZCODE_HOME}/config.json"
KNOWN_MARKETPLACES="${ZCODE_HOME}/plugins/known_marketplaces.json"
ENABLE_KEY="${PLUGIN_NAME}@${MARKETPLACE_NAME}"

c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_bold()  { printf '\033[1m%s\033[0m' "$1"; }
log()  { printf '%s %s\n' "$(c_green '✓')" "$1"; }

echo "$(c_bold 'Desinstalar ValorBrain Plugin')"
echo ""

# Remove cache
if [ -d "$CACHE_DIR" ]; then
  rm -rf "$CACHE_DIR"
  log "Removido: ${CACHE_DIR}"
else
  echo "Cache não encontrado (já removido?)."
fi

# Remove marketplace registry
if [ -d "$MARKETPLACE_DIR" ]; then
  rm -rf "$MARKETPLACE_DIR"
  log "Removido: ${MARKETPLACE_DIR}"
fi

# Remove data dirs — INCLUDING vbctl's (data/<name> holds config.env with the token)
for d in "$DATA_DIR" "$VBCTL_DATA_DIR"; do
  if [ -d "$d" ]; then
    rm -rf "$d"
    log "Removido: ${d}"
  fi
done

# Deregister marketplace from known_marketplaces.json (if registered)
if [ -f "$KNOWN_MARKETPLACES" ] && command -v jq >/dev/null 2>&1; then
  if jq -e --arg mkt "$MARKETPLACE_NAME" '.marketplaces[] | select(.id == $mkt)' "$KNOWN_MARKETPLACES" >/dev/null 2>&1; then
    tmp=$(mktemp)
    jq --arg mkt "$MARKETPLACE_NAME" 'del(.marketplaces[] | select(.id == $mkt))' \
      "$KNOWN_MARKETPLACES" > "$tmp" && mv "$tmp" "$KNOWN_MARKETPLACES"
    log "Marketplace '${MARKETPLACE_NAME}' desregistrado do known_marketplaces.json"
  fi
fi

# Disable in config.json (preserve everything else, including MCP entry)
if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq --arg k "$ENABLE_KEY" 'del(.plugins.enabledPlugins[$k])' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  log "Plugin desabilitado no config.json (MCP entry preservado)"
fi

echo ""
echo "$(c_green '✓') Desinstalação completa."
echo "  O MCP entry no config.json foi preservado — remova manualmente se desejar."
echo "  Reinicie o ZCode para aplicar."
