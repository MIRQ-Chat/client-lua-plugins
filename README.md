# MIRQ Client Lua Plugins: AI Chat and Collaboration Assistants

MIRQ Client Lua Plugins bring local-first AI chat, guild collaboration helpers, and workflow automation directly into MIRQ channels and DMs.

If you are looking for:
- AI chat in MIRQ with local model support
- Team collaboration assistants for shared channels
- Privacy-aware plugin automation with local memory

this repository is the starting point.

## Included Components

| Component | What it does | Main triggers | Local dependency |
|---|---|---|---|
| `hello-world` | Minimal plugin sanity check | (none) | none |
| `lmstudio-assistant` | Local AI assistant with memory, skills, and optional MCP tool calls | `/ai ...`, `@ai ...` | LM Studio API (`127.0.0.1:1234`) |
| `otacon-assistant` | OpenClaw-to-MIRQ integration assistant with trust controls, privacy modes, and guild context | `/otacon ...`, `otacon ...`, `@openclaw ...` | Otacon bridge (`127.0.0.1:8787`) |
| `otacon-bridge` | Python localhost bridge for `otacon-assistant` | HTTP endpoints | Python 3 + `openclaw` CLI |

## Quick Start

1. Copy plugin folders into your MIRQ client plugin directory.
2. Open MIRQ and click the `Plugins` button in the footer.
3. Click `Run / Reload` in the plugin editor.
4. Start the local backend(s):
   - `otacon-assistant`: run the bridge
   - `lmstudio-assistant`: run LM Studio local server

## Plugin Install Location

MIRQ client-side plugins are loaded from:
- Windows: `%LOCALAPPDATA%\mirq\plugins\`
- macOS: `~/Library/Application Support/mirq/plugins/`
- Linux: `~/.local/share/mirq/plugins/`

Each plugin must contain:
- `plugin.json`
- `main.lua`

### Example Copy (Windows PowerShell)

```powershell
Copy-Item -Recurse -Force .\hello-world "$env:LOCALAPPDATA\mirq\plugins\"
Copy-Item -Recurse -Force .\lmstudio-assistant "$env:LOCALAPPDATA\mirq\plugins\"
Copy-Item -Recurse -Force .\otacon-assistant "$env:LOCALAPPDATA\mirq\plugins\"
```

## How MIRQ Uses These Plugins in the Client

- MIRQ discovers plugin subfolders with `plugin.json`.
- Manifest fields are validated (`id`, `entry`, `apiVersion`, `capabilities`).
- Supported API version is `1.x`.
- Runtime hooks include `onLoad`, `onUnload`, `onMessageCreate`, and optional `onTick`.
- Capability gates are enforced (for example `chat:write`, `dm:write`, `http:localhost`).
- `mirq.http.post(...)` is restricted to localhost for client plugin security.
- Plugin local memory/skills persist in plugin state (`.mirq_state.json`).
- Plugin callbacks run with an instruction budget to reduce runaway scripts.
- In client startup flow, bundled `otacon-assistant` and `lmstudio-assistant` are synced into runtime plugin storage when available.
- Plugin-authored messages are visually identified in the MIRQ UI flow.

## Plugin Usage

### `otacon-assistant` (OpenClaw collaboration assistant)

`otacon-assistant` is designed specifically to integrate the OpenClaw assistant with MIRQ chat channels and DMs.

OpenClaw:
- Website: `https://openclaw.ai/`
- CLI is used by the local bridge (`openclaw agent ...`) to generate responses.

Default bridge endpoints in `otacon-assistant/main.lua`:
- Sync: `http://127.0.0.1:8787/mirq/assist` (default mode)
- Async: `http://127.0.0.1:8787/mirq/submit` + `http://127.0.0.1:8787/mirq/outbox`

To switch to async mode, set `transport_mode = "submit_async"` in `otacon-assistant/main.lua`.

Commands:
- `/otacon help`
- `/otacon enable | /otacon disable`
- `/otacon privacy <strict|balanced|open>` (admin)
- `/otacon whoactive`
- `/otacon profile [user_id]`
- `/otacon remember <fact>`
- `/otacon admin add <user_id> | remove <user_id> | list` (admin)
- `/otacon trust set <user_id> <blocked|low|normal|high>` (admin)

Behavior highlights:
- Works in channels and DMs.
- Adds requester trust/admin and guild context into bridge payload.
- Includes privacy guardrails before forwarding sensitive requests.
- Supports channel and guild allowlists in config.

### Run the Otacon Bridge

From this repo:

```bash
python otacon-bridge/otacon_bridge.py
```

Optional bridge environment settings:
- `OTACON_ALLOWED_GUILD_IDS`
- `OTACON_ALLOWED_CHANNEL_IDS`
- `OTACON_SESSION_MODE` (`author` or `channel`)
- `OTACON_AGENT_TIMEOUT_SECONDS`

### `lmstudio-assistant` (local AI chat and knowledge helper)

Default model endpoint in `lmstudio-assistant/main.lua`:
- `http://127.0.0.1:1234/v1/chat/completions`

Default MCP endpoint:
- `http://127.0.0.1:8788/mcp/call`

Commands:
- `/ai help`
- `/ai enable | /ai disable`
- `/ai remember <fact>`
- `/ai profile`
- `/ai skill set <name> <text>`
- `/ai skill get <name> | /ai skill list | /ai skill del <name>`
- `/ai mcp <server> <tool> <json-args>`

Behavior highlights:
- Responds to `/ai ...`, `@ai ...`, and DMs.
- Builds lightweight profile/history and channel memory context.
- Supports local reusable skills and optional localhost MCP tool routing.

### `hello-world`

Minimal starter plugin used to verify load and logging:
- `hello-world/main.lua`
- Logs a startup message with `mirq.log(...)`.

## Troubleshooting

- Plugin not loading:
  - Confirm `plugin.json` is valid JSON.
  - Confirm `entry` file exists.
  - Confirm `apiVersion` is compatible (`1.x`).
- `Otacon bridge` errors:
  - Ensure bridge is running on `127.0.0.1:8787`.
  - Verify allowlist env vars are not blocking your guild/channel.
- `LM Studio` errors:
  - Ensure local server is running on `127.0.0.1:1234`.
  - Confirm a model is loaded and OpenAI-compatible endpoint is enabled.
- HTTP permission errors:
  - Client plugins only allow localhost HTTP calls by design.

## Repository Layout

```text
client-lua-plugins/
  hello-world/
  lmstudio-assistant/
  otacon-assistant/
  otacon-bridge/
```

## References Used

- `D:\KNS\MIRQ\docs\CLIENT_LUA_PLUGIN_SPEC.md`
- `D:\KNS\MIRQ\docs\OTACON_BRIDGE_RUNBOOK.md`
- `D:\KNS\MIRQ\docs\OTACON_BRIDGE_API.md`
- `D:\KNS\MIRQ\landing_page\docs\articles\user-guide\lua-plugins.md`
- `D:\KNS\MIRQ\src\client_hmi\hmi_window_lua.cpp`
- `D:\KNS\MIRQ\src\client_hmi\lua_plugin_manager.cpp`
