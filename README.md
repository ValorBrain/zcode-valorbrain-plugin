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

| Sintoma | Causa | Solução |
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
