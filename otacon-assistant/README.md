# Otacon / OpenClaw Assistant (v0.4.0)

This plugin integrates MIRQ with a localhost OpenClaw bridge and adds:

- Guild-aware context for the bridge (active members, requester trust/admin state, channel memory)
- Persistent member profiles and short conversation history
- Privacy and trust guardrails before forwarding prompts
- Admin controls for policy/trust

## Required capabilities

`events`, `chat:write`, `dm:write`, `http:localhost`, `memory:local`

## Bridge endpoints

Configured in `main.lua`:

- `submit_url`: `http://127.0.0.1:8787/mirq/submit`
- `outbox_url`: `http://127.0.0.1:8787/mirq/outbox`

## Commands

- `/otacon help`
- `/otacon enable | /otacon disable`
- `/otacon privacy <strict|balanced|open>` (admin)
- `/otacon whoactive`
- `/otacon profile [user_id]`
- `/otacon remember <fact>`
- `/otacon admin add <user_id> | remove <user_id> | list` (admin)
- `/otacon trust set <user_id> <blocked|low|normal|high>` (admin)

## Privacy and trust model

- `blocked` users are denied forwarding.
- Sensitive requests (tokens, credentials, private/admin data, etc.) are denied unless requester is admin, or high-trust in non-`strict` mode.
- `strict` mode reduces memory context exposure and enforces tighter restrictions.

## Payload additions to bridge

The plugin includes these bridge fields in submit payloads:

- `requester_trust`
- `requester_is_admin`
- `privacy_mode`
- `guild_context` (text block with active members snapshot, requester profile/history, relevant channel facts, and safety directives)

Your bridge can ignore unknown fields, but should use these fields for safer and more context-aware responses.
