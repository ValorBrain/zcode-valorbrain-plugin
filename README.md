# ValorBrain ZCode Plugin

Memória persistente e conhecimento estruturado para agentes ZCode. Integra o [ValorBrain](https://valor.digital) via MCP, com hooks automáticos de contexto e skill de workflow.

Funciona em macOS, Linux e Windows (Git Bash). Idempotente — pode reinstalar sem medo.

## O que faz

| Hook | Evento | Ação | Custo |
|------|--------|------|-------|
| `session-start` | SessionStart | Injeta perfil + briefing do workspace | 1x/sessão, read |
| `user-prompt-submit` | UserPromptSubmit | Recupera contexto relevante da memória pra cada prompt | por prompt, read (toggle) |
| `post-tool-use` | PostToolUse (Edit/Write) | Lembra o agente de gravar decisões não-triviais (7 critérios) | ~0, write-gate (toggle) |
| `stop` | Stop | Lembra de registrar handoff em sessões significativas | ~0 |

**Skill `valorbrain-memory`:** guia recall/store/handoff/health com mapa das 31 tools MCP.

A decisão de **gravar** é sempre do agente — hooks só injetam lembretes. Leitura é automática.

## Instalação rápida

### Pré-requisitos

- `jq` e `curl` instalados (no Windows: `winget install jqlang.jq`; Git Bash já traz curl)
- `rsync` opcional — com fallback automático para `cp` (Windows Git Bash não tem rsync)
- ZCode instalado (`~/.zcode/cli/`)
- Um token ValorBrain `vbm_...` (obtenha no painel do ValorBrain)

### Passo a passo

```bash
# 1. Clone o repo
git clone https://github.com/valordigital/zcode-valorbrain-plugin.git
cd zcode-valorbrain-plugin

# 2. Instale (interativo — pergunta o token se não encontrar)
./install.sh

# Ou não-interativo:
./install.sh --token vbm_SEU_TOKEN_AQUI

# Ou via env var:
VALORBRAIN_MCP_TOKEN=vbm_SEU_TOKEN_AQUI ./install.sh

# 3. Reinicie o ZCode
```

O `install.sh` é **idempotente** — pode rodar várias vezes. Ele:

1. Valida seu token contra o MCP (health-check antes de instalar).
2. Copia o plugin pro cache do ZCode.
3. Registra o marketplace `valor-digital`.
4. Configura o MCP (lógica híbrida — ver abaixo).
5. Habilita o plugin no `config.json`.
6. Cria o data dir com `config.env` template.
7. Roda smoke test do `vbctl`.

### Lógica híbrida de MCP

O `install.sh` detecta seu ambiente automaticamente:

- **Já tem MCP global** no `~/.zcode/cli/config.json` (`mcp.servers.valorbrain`)? → o plugin usa esse. Remove `mcpServers` do `plugin.json` pra evitar conflito de nome duplicado.
- **Não tem MCP global**? → injeta a entrada MCP no `config.json` pra você.

Em ambos os casos, o `vbctl` (usado pelos hooks) lê credenciais do `config.json`.

## Configuração

### Ordem de precedência de credenciais

`vbctl` resolve URL + token nesta ordem:

1. **Env vars:** `VALORBRAIN_MCP_URL`, `VALORBRAIN_MCP_TOKEN`
2. **Plugin data dir:** `~/.zcode/cli/plugins/data/valorbrain@valor-digital/config.env`
3. **Global:** `~/.zcode/cli/config.json` (`mcp.servers.valorbrain`)
4. **Default URL:** `https://mcpbrain.valor.digital/mcp`

### Toggles

| userConfig key | Env var | Default | Controla |
|----------------|---------|---------|----------|
| `auto_prepare` | `VALORBRAIN_AUTO_PREPARE` | `true` | Hook UserPromptSubmit (recall por prompt) |
| `write_reminder` | `VALORBRAIN_WRITE_REMINDER` | `true` | Hook PostToolUse (lembrete de gravação) |

Pra desabilitar (ex: máquina lenta, sessão que não precisa de recall):

```bash
export VALORBRAIN_AUTO_PREPARE=false
export VALORBRAIN_WRITE_REMINDER=false
```

Ou defina no `userConfig` do plugin.

### Rotação de token

1. Gere um novo token no painel do ValorBrain.
2. Atualize no `~/.zcode/cli/config.json` (`mcp.servers.valorbrain.headers.Authorization`).
3. Reinstale com o novo token: `./install.sh --token vbm_NOVO_TOKEN`.
4. Revogue o token antigo no painel.

## Multi-tenant (clientes)

Cada cliente/tenant tem seu próprio token `vbm_...` que isola o vault de memória. Não há configuração especial de multi-tenant no plugin — o token determina o tenant no backend ValorBrain.

Pra múltiplos tenants na mesma máquina, use env vars por projeto:

```bash
# No .envrc ou shell profile do projeto
export VALORBRAIN_MCP_TOKEN=vbm_TOKEN_DO_CLIENTE_A
```

Ou mantenha `config.env` separados por projeto apontando `VALORBRAIN_PLUGIN_DATA` pra dirs distintos.

## Desinstalação

```bash
./install.sh --uninstall
# ou
./uninstall.sh
```

Remove: cache do plugin, marketplace registry, data dir, desabilita no `config.json`. **Preserva** a entrada MCP no `config.json` (remova manualmente se quiser desconectar totalmente).

## Arquitetura

```
hooks/ (eventos bash) → bin/vbctl (bridge curl+jq) → MCP remoto (HTTP)
                                  ↑
skills/valorbrain-memory guia o agente (invoca mcp__valorbrain__*)
```

Hooks são "burros": injetam contexto e lembretes via `additionalContext`, nunca gravam sozinhos. A decisão de gravar fica com o agente, guiado pelos 7 critérios na skill. Leitura (profile, briefing, recall) é automática e segura.

### Estrutura de arquivos

```
zcode-valorbrain-plugin/
├── .zcode-plugin/plugin.json   # manifesto (skills, hooks, userConfig)
├── .zcode-plugin-seed.json     # fingerprint do marketplace
├── package.json
├── install.sh                  # instalador idempotente (lógica híbrida)
├── uninstall.sh                # remoção limpa
├── marketplace.json            # registry valor-digital
├── bin/vbctl                   # CLI helper (bash + curl + jq, stateless)
├── hooks/
│   ├── hooks.json              # registro dos 4 hooks
│   ├── run-hook.cmd            # dispatcher polyglot (bash+cmd)
│   ├── session-start           # SessionStart: profile + briefing
│   ├── user-prompt-submit      # UserPromptSubmit: memory_prepare
│   ├── post-tool-use           # PostToolUse: 7 critérios write-gate
│   └── stop                    # Stop: handoff reminder
└── skills/
    └── valorbrain-memory/SKILL.md  # 4 workflows + mapa das 31 tools
```

## Troubleshooting

| Sintoma | Causa provável | Solução |
|---------|----------------|---------|
| `ValorBrain MCP indisponível` no SessionStart | MCP down ou token inválido | `./bin/vbctl ping` pra diagnosticar; verifique token no config.json |
| Sem `<valorbrain-recall>` nos prompts | `auto_prepare=false` ou recall vazio | Habilite toggle; se recall legítimo vazio, é normal |
| `vbctl: MCP request failed` | rede, auth, ou URL errada | `./bin/vbctl ping`; verifique `VALORBRAIN_MCP_URL` |
| `vbctl: no token resolved` | sem token em nenhum nível | `./install.sh --token vbm_...` ou exporte `VALORBRAIN_MCP_TOKEN` |
| Hooks não disparam após install | ZCode não reiniciou | Reinicie o ZCode (hooks carregam no startup) |
| Plugin não aparece | não habilitado no config.json | `jq '.plugins.enabledPlugins' ~/.zcode/cli/config.json` deve ter `valorbrain@valor-digital: true` |

### Debug manual

```bash
# Testar vbctl isolado
./bin/vbctl ping
./bin/vbctl profile
./bin/vbctl prepare "teste de recall"

# Testar hooks isoladamente (simula o que o runtime faz)
export CLAUDE_PLUGIN_ROOT="$(pwd)"
./hooks/session-start | jq .
echo '{"prompt":"teste"}' | ./hooks/user-prompt-submit | jq .
echo '{"tool_name":"Write"}' | ./hooks/post-tool-use | jq .
./hooks/stop | jq .
```

## Desenvolvimento

```bash
# Repo
git clone https://github.com/valordigital/zcode-valorbrain-plugin.git
cd zcode-valorbrain-plugin

# Iterar num hook, testar, reinstalar
vim hooks/session-start
./hooks/session-start | jq .   # testar
./install.sh                    # reinstalar no cache

# Versionamento: semver. MCP schema breaking = major bump.
git tag v0.2.0
```

## Requisitos

- macOS ou Linux
- `jq` 1.6+
- `curl`
- `rsync` (apenas pro install.sh)
- ZCode (`~/.zcode/cli/`)

## Licença

MIT © [Valor Digital](https://valor.digital)
