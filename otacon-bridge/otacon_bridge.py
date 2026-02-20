#!/usr/bin/env python3
"""
OTACON real localhost bridge for MIRQ plugin.

Inbound (MIRQ → OpenClaw):
  POST /mirq/submit   — async: queues request, returns immediately (preferred)
  POST /mirq/assist   — sync:  blocks until openclaw agent responds (legacy)

Outbound (OpenClaw → MIRQ, two-way):
  POST /mirq/push     — OpenClaw pushes a message into the outbox queue
  GET  /mirq/outbox   — Plugin polls and drains pending outbound messages

Environment variables:
  OTACON_BRIDGE_HOST=127.0.0.1
  OTACON_BRIDGE_PORT=8787
  OTACON_ALLOWED_GUILD_IDS=1,2,3         (optional allowlist)
  OTACON_ALLOWED_CHANNEL_IDS=10,20,30    (optional allowlist)
  OTACON_SESSION_PREFIX=mirq
  OTACON_SESSION_MODE=channel            (author|channel)
  OTACON_AGENT_TIMEOUT_SECONDS=0         (0 = unlimited; was 180)
  OTACON_MAX_BODY_BYTES=2097152          (max inbound payload, default 2 MB)
  OTACON_THINKING=low                    (off|minimal|low|medium|high)
  OTACON_AGENT_ID=                       (optional)
  OTACON_DEFAULT_CHANNEL=HMB:Otacon     (default channel for push messages)
  OTACON_WORKERS=3                       (async worker threads for /mirq/submit)
"""

from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _intset_from_env(name: str) -> set[int]:
    raw = os.getenv(name, "").strip()
    out: set[int] = set()
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            out.add(int(part))
        except ValueError:
            pass
    return out


HOST = os.getenv("OTACON_BRIDGE_HOST", "127.0.0.1")
PORT = int(os.getenv("OTACON_BRIDGE_PORT", "8787"))
ALLOWED_GUILDS = _intset_from_env("OTACON_ALLOWED_GUILD_IDS")
ALLOWED_CHANNELS = _intset_from_env("OTACON_ALLOWED_CHANNEL_IDS")
SESSION_PREFIX = os.getenv("OTACON_SESSION_PREFIX", "mirq").strip() or "mirq"
SESSION_MODE = os.getenv("OTACON_SESSION_MODE", "channel").strip().lower()
AGENT_TIMEOUT = int(os.getenv("OTACON_AGENT_TIMEOUT_SECONDS", "0"))  # 0 = unlimited
MAX_BODY_BYTES = int(os.getenv("OTACON_MAX_BODY_BYTES", str(2 * 1024 * 1024)))
THINKING = os.getenv("OTACON_THINKING", "low").strip().lower()
AGENT_ID = os.getenv("OTACON_AGENT_ID", "").strip()
DEFAULT_CHANNEL = os.getenv("OTACON_DEFAULT_CHANNEL", "HMB:Otacon").strip()
NUM_WORKERS = int(os.getenv("OTACON_WORKERS", "3"))

if SESSION_MODE not in {"author", "channel"}:
    SESSION_MODE = "channel"
if THINKING not in {"off", "minimal", "low", "medium", "high"}:
    THINKING = "low"

# Thread-safe outbox queue: items = {"channel": str|int, "message": str, "is_dm": bool, "thread_id": int}
_outbox: queue.Queue = queue.Queue()

# Async work queue for /mirq/submit
_work_queue: queue.Queue = queue.Queue()


def make_session_id(payload: dict) -> str:
    is_dm = bool(payload.get("is_dm", False))
    guild_id = int(payload.get("guild_id") or 0)
    channel_id = int(payload.get("channel_id") or 0)
    thread_id = int(payload.get("thread_id") or 0)
    author_id = int(payload.get("author_id") or 0)
    # DMs always get a per-user session (thread_id is a stable DM thread identifier)
    if is_dm:
        tid = thread_id or channel_id
        return f"{SESSION_PREFIX}-dm-t{tid}-u{author_id}"
    if SESSION_MODE == "channel":
        return f"{SESSION_PREFIX}-g{guild_id}-c{channel_id}"
    return f"{SESSION_PREFIX}-g{guild_id}-c{channel_id}-u{author_id}"


def build_agent_message(payload: dict) -> str:
    prompt = str(payload.get("prompt") or "").strip()
    source = str(payload.get("source") or "mirq-plugin").strip() or "mirq-plugin"
    integration = str(payload.get("integration") or "MIRQ").strip() or "MIRQ"
    is_dm = bool(payload.get("is_dm", False))
    visibility = str(payload.get("visibility") or ("dm" if is_dm else "shared-channel")).strip()
    multi_user = bool(payload.get("multi_user", not is_dm))
    guild_id = int(payload.get("guild_id") or 0)
    channel_id = int(payload.get("channel_id") or 0)
    thread_id = int(payload.get("thread_id") or 0)
    author_id = int(payload.get("author_id") or 0)
    author_handle = str(payload.get("author_handle") or "unknown").strip() or "unknown"

    if is_dm:
        context_line = (
            "[Context] This message is from a MIRQ Direct Message (private, one-on-one). "
            f"source={source}; integration={integration}; visibility=dm; multi_user=false; "
            f"thread_id={thread_id}; channel_id={channel_id}; sender=@{author_handle} (author_id={author_id}).\n"
            "This is a private conversation — be direct, personal, and concise."
        )
    else:
        context_line = (
            "[Context] This message is from MIRQ. "
            f"source={source}; integration={integration}; visibility={visibility}; multi_user={str(multi_user).lower()}; "
            f"guild_id={guild_id}; channel_id={channel_id}; sender=@{author_handle} (author_id={author_id}).\n"
            "Multiple people can see and interact in this space, so keep replies socially aware and attribute user intent to the sender above."
        )

    return f"{context_line}\n\n[Sender @{author_handle}] {prompt}"


def _coerce_text(value) -> str | None:
    if isinstance(value, str):
        text = value.strip()
        return text or None
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            extracted = _extract_text(item)
            if extracted:
                parts.append(extracted)
        if parts:
            return "\n".join(parts).strip()
    if isinstance(value, dict):
        # Handle common content block shapes from LLM responses.
        if isinstance(value.get("type"), str) and value.get("type") in {"text", "output_text"}:
            txt = value.get("text") or value.get("value")
            return _coerce_text(txt)
        for key in ("text", "value", "content", "message", "output_text"):
            extracted = _coerce_text(value.get(key))
            if extracted:
                return extracted
    return None


def _extract_from_assistant_message(node) -> str | None:
    if not isinstance(node, dict):
        return None
    role = str(node.get("role") or "").strip().lower()
    if role not in {"assistant", "agent", "model"}:
        return None
    for key in ("content", "text", "message", "output_text", "value"):
        extracted = _coerce_text(node.get(key))
        if extracted:
            return extracted
    return None


def _deep_find_text_candidates(node, depth: int = 0) -> list[tuple[int, str]]:
    if depth > 10:
        return []

    out: list[tuple[int, str]] = []
    if isinstance(node, dict):
        # Strong preference: role-tagged assistant messages.
        from_msg = _extract_from_assistant_message(node)
        if from_msg:
            out.append((120, from_msg))

        noisy_keys = {
            "runId", "status", "summary", "provider", "model", "sessionId",
            "durationMs", "input", "output", "cacheRead", "cacheWrite", "total",
            "usage", "lastCallUsage",
        }
        weighted_keys = {
            "output_text": 110,
            "response": 105,
            "message": 100,
            "text": 95,
            "content": 90,
            "value": 80,
            "completion": 80,
            "generated_text": 80,
            "assistant_response": 80,
            "final_response": 80,
            "final": 70,
            "answer": 70,
        }
        for key, value in node.items():
            if key in noisy_keys:
                # Some providers tuck final text inside meta trees; recurse but do not score noisy keys.
                out.extend(_deep_find_text_candidates(value, depth + 1))
                continue
            weight = weighted_keys.get(str(key), 0)
            if weight > 0:
                extracted = _coerce_text(value)
                if extracted:
                    out.append((weight, extracted))
            out.extend(_deep_find_text_candidates(value, depth + 1))
    elif isinstance(node, list):
        for item in node:
            out.extend(_deep_find_text_candidates(item, depth + 1))
    return out


def _extract_text(data) -> str | None:
    if data is None:
        return None

    direct = _coerce_text(data)
    if direct:
        return direct

    if isinstance(data, dict):
        # Prioritize known OpenClaw schema when present.
        result = data.get("result")
        if isinstance(result, dict):
            payloads = result.get("payloads")
            if isinstance(payloads, list):
                for payload in payloads:
                    text = _coerce_text(payload)
                    if text:
                        return text
        # Then try common top-level keys.
        for key in ("payloads", "output", "outputs", "response", "result"):
            text = _coerce_text(data.get(key))
            if text:
                return text

    # Fallback: deep scan for likely assistant text fields.
    candidates = _deep_find_text_candidates(data)
    if candidates:
        # Select by score first, then prefer longer non-trivial text.
        candidates.sort(key=lambda t: (t[0], len(t[1])), reverse=True)
        for _, candidate in candidates:
            cleaned = candidate.strip()
            if cleaned and cleaned.lower() not in {"ok", "completed", "success"}:
                return cleaned
    return None


def _short_json(value, limit: int = 400) -> str:
    try:
        text = json.dumps(value, ensure_ascii=False)
    except Exception:
        text = str(value)
    text = text.replace("\n", " ").strip()
    if len(text) > limit:
        return text[:limit] + "..."
    return text


def _decode_escaped_unicode(text: str) -> str:
    """Decode JSON-style unicode escapes and bare uXXXX punctuation leaks."""
    s = (text or "").strip()
    if not s:
        return s
    # Some providers leak bare forms like "youu2019d" (missing backslash).
    # Restrict to common punctuation code points to avoid mangling normal words.
    common_punct = {"2018", "2019", "201C", "201D", "2013", "2014", "2026"}
    s = re.sub(
        r"(?i)(?<!\\)\bu([0-9a-f]{4})\b",
        lambda m: ("\\u" + m.group(1)) if m.group(1).upper() in common_punct else m.group(0),
        s,
    )
    if "\\u" not in s and "\\n" not in s and "\\t" not in s:
        return s
    try:
        decoded = bytes(s, "utf-8").decode("unicode_escape")
        # If mojibake appears after unicode_escape, repair via latin1->utf8 roundtrip.
        if any(ch in decoded for ch in ("â€™", "â€œ", "â€", "â€“", "â€”", "â€¦")):
            try:
                decoded = decoded.encode("latin1", "ignore").decode("utf-8", "ignore")
            except Exception:
                pass
        return decoded
    except Exception:
        return s


def run_openclaw(message: str, session_id: str) -> tuple[str | None, str | None]:
    base_cmd = [
        "openclaw", "agent",
        "--session-id", session_id,
        "--message", message,
        "--thinking", THINKING,
    ]
    cmd = list(base_cmd)
    cmd.insert(2, "--json")
    if AGENT_TIMEOUT > 0:
        cmd.extend(["--timeout", str(AGENT_TIMEOUT)])
    if AGENT_ID:
        cmd.extend(["--agent", AGENT_ID])

    # proc_timeout: None = wait indefinitely; otherwise add a buffer over the agent timeout
    proc_timeout = None if AGENT_TIMEOUT == 0 else AGENT_TIMEOUT + 15

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=proc_timeout)
    except subprocess.TimeoutExpired:
        return None, "timeout: openclaw agent exceeded timeout"
    except Exception as e:
        return None, f"bridge execution error: {e}"

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "unknown error").strip()
        return None, f"openclaw agent failed: {err}"

    raw = (proc.stdout or "").strip()
    if not raw:
        return None, "openclaw agent returned empty output"

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None, "openclaw agent returned non-json output"

    text = _extract_text(data)
    if text:
        return _decode_escaped_unicode(text), None

    # Fallback: when JSON envelopes do not include payload text (seen with some providers),
    # retry once without --json and treat stdout as the assistant reply.
    plain_cmd = list(base_cmd)
    if AGENT_TIMEOUT > 0:
        plain_cmd.extend(["--timeout", str(AGENT_TIMEOUT)])
    if AGENT_ID:
        plain_cmd.extend(["--agent", AGENT_ID])
    try:
        plain_proc = subprocess.run(plain_cmd, capture_output=True, text=True, timeout=proc_timeout)
        if plain_proc.returncode == 0:
            plain = (plain_proc.stdout or "").strip()
            if plain:
                return _decode_escaped_unicode(plain), None
    except Exception:
        pass

    return None, f"openclaw agent response missing text payload: {_short_json(data)}"


def _make_outbox_item(payload: dict, message: str) -> dict:
    """Build an outbox item with full routing info from the original request payload."""
    is_dm = bool(payload.get("is_dm", False))
    thread_id = int(payload.get("thread_id") or 0)
    channel_id = int(payload.get("channel_id") or 0)
    # For channel messages, use the channel_id as the routing key.
    # For DMs, thread_id is the DM thread identifier.
    channel = str(channel_id) if not is_dm else DEFAULT_CHANNEL
    return {
        "channel": channel,
        "message": message,
        "is_dm": is_dm,
        "thread_id": thread_id if is_dm else 0,
        "channel_id": channel_id,
    }


def _process_work_item(payload: dict) -> None:
    """Run openclaw agent for a queued submit request, push result to outbox."""
    author_handle = str(payload.get("author_handle") or "unknown")
    session_id = make_session_id(payload)
    agent_message = build_agent_message(payload)

    print(f"[otacon-bridge] worker processing: session={session_id} author=@{author_handle}")
    text, err = run_openclaw(agent_message, session_id)

    if err:
        msg = f"⚠️ {err}"
        print(f"[otacon-bridge] worker error for session={session_id}: {err}")
    else:
        msg = text or ""
        print(f"[otacon-bridge] worker done: session={session_id} chars={len(msg)}")

    _outbox.put(_make_outbox_item(payload, msg))


def _worker_loop() -> None:
    """Background thread: drain _work_queue and process each item."""
    while True:
        payload = _work_queue.get()
        if payload is None:
            break
        try:
            _process_work_item(payload)
        except Exception as exc:
            print(f"[otacon-bridge] worker unhandled exception: {exc}")
        finally:
            _work_queue.task_done()


class Handler(BaseHTTPRequestHandler):
    # Short timeout for the handler connection itself — submit returns fast,
    # and /mirq/assist is kept only for legacy/testing use.
    timeout = 60

    def _send(self, code: int, body: str, ctype: str = "text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def _read_body(self) -> dict:
        cl = self.headers.get("content-length", "").strip()
        if cl.isdigit():
            length = min(int(cl), MAX_BODY_BYTES)
            raw = self.rfile.read(length)
        else:
            chunks: list[bytes] = []
            total = 0
            chunk_size = 8192
            while total < MAX_BODY_BYTES:
                chunk = self.rfile.read(min(chunk_size, MAX_BODY_BYTES - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
            raw = b"".join(chunks)
        try:
            return json.loads(raw.decode("utf-8", "replace")) if raw else {}
        except Exception:
            return {}

    def _validate_request(self, body: dict) -> str | None:
        """Validate common fields. Returns error string or None if OK."""
        prompt = str(body.get("prompt") or "").strip()
        if not prompt:
            return "missing prompt"
        guild_id = int(body.get("guild_id") or 0)
        channel_id = int(body.get("channel_id") or 0)
        if ALLOWED_GUILDS and guild_id not in ALLOWED_GUILDS:
            return "forbidden: guild not allowed"
        if ALLOWED_CHANNELS and channel_id not in ALLOWED_CHANNELS:
            return "forbidden: channel not allowed"
        return None

    def do_GET(self):
        if self.path != "/mirq/outbox":
            self._send(404, "not found")
            return

        messages = []
        while True:
            try:
                messages.append(_outbox.get_nowait())
            except queue.Empty:
                break

        self._send(200, json.dumps(messages), "application/json; charset=utf-8")

    def do_POST(self):
        if self.path == "/mirq/submit":
            self._handle_submit()
        elif self.path == "/mirq/assist":
            self._handle_assist()
        elif self.path == "/mirq/push":
            self._handle_push()
        elif self.path in ("/mirq/outbox", "/mirq/outbox-drain"):
            self._handle_outbox_drain()
        else:
            self._send(404, "not found")

    def _handle_submit(self):
        """Async: queue the request, return immediately. Response arrives via outbox."""
        body = self._read_body()
        err = self._validate_request(body)
        if err:
            code = 403 if "forbidden" in err else 400
            self._send(code, err)
            return

        _work_queue.put(body)
        qsize = _work_queue.qsize()
        print(f"[otacon-bridge] queued request from @{body.get('author_handle','?')} (queue depth: {qsize})")
        self._send(200, json.dumps({"status": "queued", "queue_depth": qsize}),
                   "application/json; charset=utf-8")

    def _handle_assist(self):
        """Legacy sync endpoint: blocks until response ready. Kept for testing."""
        body = self._read_body()
        err = self._validate_request(body)
        if err:
            code = 403 if "forbidden" in err else 400
            self._send(code, err)
            return

        session_id = make_session_id(body)
        agent_message = build_agent_message(body)
        text, err = run_openclaw(agent_message, session_id)
        if err:
            self._send(502, err)
            return
        self._send(200, text or "")

    def _handle_push(self):
        body = self._read_body()
        message = str(body.get("message") or "").strip()
        channel = body.get("channel") or DEFAULT_CHANNEL
        is_dm = bool(body.get("is_dm", False))
        thread_id = int(body.get("thread_id") or 0)

        if not message:
            self._send(400, "missing message")
            return

        _outbox.put({"channel": channel, "message": message, "is_dm": is_dm, "thread_id": thread_id})
        print(f"[otacon-bridge] outbox queued → {channel}: {message[:80]}")
        self._send(200, "queued")

    def _handle_outbox_drain(self):
        messages = []
        while True:
            try:
                messages.append(_outbox.get_nowait())
            except queue.Empty:
                break
        self._send(200, json.dumps(messages), "application/json; charset=utf-8")

    def log_message(self, fmt: str, *args):
        pass


def main():
    print(f"[otacon-bridge] listening on http://{HOST}:{PORT}")
    print(f"[otacon-bridge] async:    POST /mirq/submit  (preferred)")
    print(f"[otacon-bridge] sync:     POST /mirq/assist  (legacy/testing)")
    print(f"[otacon-bridge] outbound: POST /mirq/push | GET /mirq/outbox")
    print(f"[otacon-bridge] session mode={SESSION_MODE}, prefix={SESSION_PREFIX}, thinking={THINKING}")
    print(f"[otacon-bridge] agent timeout={'unlimited' if AGENT_TIMEOUT == 0 else f'{AGENT_TIMEOUT}s'}")
    print(f"[otacon-bridge] workers={NUM_WORKERS}, default channel={DEFAULT_CHANNEL}")
    if ALLOWED_GUILDS:
        print(f"[otacon-bridge] allowed guilds={sorted(ALLOWED_GUILDS)}")
    if ALLOWED_CHANNELS:
        print(f"[otacon-bridge] allowed channels={sorted(ALLOWED_CHANNELS)}")

    # Start async worker threads
    for i in range(NUM_WORKERS):
        t = threading.Thread(target=_worker_loop, daemon=True, name=f"otacon-worker-{i}")
        t.start()
    print(f"[otacon-bridge] {NUM_WORKERS} worker threads started")

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        # Signal workers to stop
        for _ in range(NUM_WORKERS):
            _work_queue.put(None)
        server.server_close()
        print("[otacon-bridge] stopped")


if __name__ == "__main__":
    main()
