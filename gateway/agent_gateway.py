#!/usr/bin/env python3
"""Agent gateway: one local REST + SSE API for the REAPER chat panel.

Gamut agents are forwarded to the Gamut desktop API (POST bodies' "config" is turned into Gamut's
model/llmProviderId/effort; GET /config is generated from Gamut's model catalog). ACP agents (Codex, Claude Code,
Gemini CLI, ...) run as stdio subprocesses and are served under the same routes, as agents with slug `acp-<slug>`:

  GET  /api/agents                                   Gamut agents + ACP agents
  GET  /api/agents/<slug>/config                     model / effort / mode selectors (normalized config options)
  GET  /api/agents/<slug>/status[?probe=1|<slug>]    ACP: {state, connected, running, authMethods, error}. probe=1 is a
                                                     cheap check (binary present + last-known login, nothing spawned);
                                                     probe=<slug> starts that agent to find out
  POST /api/agents/<slug>/auth          {methodId}   ACP: start login (terminal methods open Terminal.app)
  GET  /api/agents/<slug>/sessions
  POST /api/agents/<slug>/sessions      {message, config}
  GET  /api/agents/<slug>/sessions/<id>
  POST /api/agents/<slug>/sessions/<id>/messages {content, config}
  GET  /api/agents/<slug>/sessions/<id>/messages[?after=<msgId>]  plain array; with after: {"after", "messages"}
                                                     (strictly newer), or {"full": true, "messages"} if msgId is unknown
  GET  /api/agents/<slug>/sessions/<id>/stream       SSE: connected, session_active, stream_delta, tool_use_ready,
                                                     session_idle, session_error, notice, permission_request,
                                                     permission_resolved, config_options
  POST /api/agents/<slug>/sessions/<id>/interrupt
  POST /api/agents/<slug>/sessions/<id>/permission {requestId, optionId|null}
  POST /api/agents/<slug>[/sessions/<id>]/upload-file   multipart "file" -> {success, path, filename, size}
  GET  /api/hibiki/brain                             {path, exists, count, defaults, off, ids, defaults_path, dir,
                                                     chars, max, folders}: the rules for agents (count = rules.md's,
                                                     defaults = the user's copy of defaults.md)
  POST /api/hibiki/brain           {add} | {ensure}  append one rule line (and rewrite the agents' instruction files;
                                                     "off: <id>" must name a default, else 400), or create rules.md
                                                     and defaults.md (seeded) so they can be opened

Attachments use Gamut's convention: the message ends with "[Attached files:]" and "- <path>" lines. For ACP agents
the gateway also sends each file as a prompt block (an image block when the agent accepts images, otherwise a
resource_link).

Stdlib only; runs on macOS' /usr/bin/python3 (3.9). Listens on 127.0.0.1 only and refuses browser requests
(any Origin header) and foreign Host headers, so web pages can't drive local agents. Every route except /health
needs "Authorization: Bearer <token>" from the 0600 token file: Docker and Lima forward the host names below to the
Mac's loopback, so containers reach this port and the bind address alone doesn't keep them out.
"""

import base64
import email
import email.policy
import hmac
import json
import mimetypes
import os
import queue
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("AGENT_GATEWAY_PORT", "47892"))
GAMUT = os.environ.get("GAMUT_URL", "http://127.0.0.1:47891").rstrip("/")
CONFIG = Path(os.environ.get("AGENT_GATEWAY_CONFIG", "~/.config/agent-gateway/config.json")).expanduser()
TOKEN_FILE = Path(os.environ.get("AGENT_GATEWAY_TOKEN_FILE", str(CONFIG.parent / "token"))).expanduser()
STATE = Path(os.environ.get("AGENT_GATEWAY_STATE", str(CONFIG.parent / "sessions"))).expanduser()
ACP_PREFIX = "acp-"
AUTH_REQUIRED = -32000
# localhost plus the names container runtimes give the host (Lima, Docker, Podman)
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "host.docker.internal", "host.lima.internal", "host.containers.internal"}
SSE_QUEUE_MAX = 2000
MAX_UPLOAD = 50 * 1024 * 1024
MAX_IMAGE_BLOCK = 10 * 1024 * 1024
ATTACHED = "[Attached files:]"  # Gamut's attachment block, appended to a message as "- <path>" lines
LOGIN_POLL = float(os.environ.get("AGENT_GATEWAY_LOGIN_POLL", "3"))
LOGIN_TIMEOUT = 900
IDLE_STOP = float(os.environ.get("AGENT_GATEWAY_IDLE", "600"))
IDLE_CHECK = float(os.environ.get("AGENT_GATEWAY_IDLE_CHECK", "30"))
MAX_REQUESTS = int(os.environ.get("AGENT_GATEWAY_MAX_REQUESTS", "32"))
MAX_STREAMS = int(os.environ.get("AGENT_GATEWAY_MAX_STREAMS", "64"))
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+$")
# Hibiki brain: rules for agents = the user's defaults.md (seeded from the package's brain/defaults.md) + rules.md,
# composed by reaper_mcp/brain.py (the MCP server sends the same text as its instructions). The gateway writes it into
# the agents' working folder as a marked block in the instruction file each CLI reads by itself (Codex / Kimi / Copilot
# AGENTS.md, Claude Code CLAUDE.md, Gemini GEMINI.md), before each new or reloaded session.
if str(Path(__file__).resolve().parents[1]) not in sys.path:  # the clone or installed app this file sits in
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from reaper_mcp import brain as hibiki_brain  # noqa: E402 - stdlib only, from the same tree as this file

BRAIN = hibiki_brain.user_dir()
BRAIN_FILES = ("AGENTS.md", "CLAUDE.md", "GEMINI.md")
BRAIN_BEGIN = ("<!-- hibiki rules: begin. Written by the Hibiki gateway from defaults.md + rules.md in %s; edit those, "
               "not this block -->")
BRAIN_END = "<!-- hibiki rules: end -->"
BRAIN_MAX = hibiki_brain.BRAIN_MAX
ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def expand(v):
    return os.path.expandvars(os.path.expanduser(v)) if isinstance(v, str) else v


def load_config():
    if CONFIG.exists():
        return json.loads(CONFIG.read_text())
    return {"acp": [], "mcpServers": []}


WINDOWS = os.name == "nt"


def safe_id(v):
    return isinstance(v, str) and len(v) <= 200 and bool(SAFE_ID.match(v)) and v not in (".", "..")


def cmd_value(s):
    """Text for a line of a .cmd file: a quote or line break would end the argument, a bare % would expand a variable."""
    s = str(s)
    if any(c in s for c in '"\r\n\0'):
        raise ValueError("cannot pass %r to cmd.exe safely" % s)
    return s.replace("%", "%%")


def cmd_quote(s):
    """One cmd.exe argument. Inside double quotes cmd takes & | < > ^ literally."""
    return '"%s"' % cmd_value(s)


def shell_line(argv, env=None, cwd=None, path_prefix=None):
    """A command line for a visible terminal: POSIX sh on macOS/Linux, cmd.exe on Windows."""
    bad = [k for k in (env or {}) if not ENV_KEY.match(str(k))]
    if bad:
        raise ValueError("bad environment variable name %r" % bad[0])
    if WINDOWS:
        parts = ["cd /d %s" % cmd_quote(cwd)] if cwd else []
        if path_prefix:
            parts.append('set "PATH=%s;%%PATH%%"' % cmd_value(path_prefix))
        parts += ['set "%s=%s"' % (k, cmd_value(v)) for k, v in (env or {}).items()]
        parts.append(" ".join(cmd_quote(a) for a in argv))
        return " && ".join(parts)
    out = "cd %s && " % shlex.quote(cwd) if cwd else ""
    out += "".join("export %s=%s; " % (k, shlex.quote(str(v))) for k, v in (env or {}).items())
    if path_prefix:
        out += "PATH=%s:\"$PATH\" exec " % shlex.quote(path_prefix)
    return out + " ".join(shlex.quote(a) for a in argv)


def open_terminal(command):
    """Run a shell command in a visible terminal (Terminal.app / a cmd.exe console; AGENT_GATEWAY_TERMINAL overrides
    the launcher)."""
    custom = os.environ.get("AGENT_GATEWAY_TERMINAL")
    if custom:
        if WINDOWS:  # a string goes to CreateProcess as is; a list would get its quotes \-escaped, which cmd ignores
            subprocess.Popen(custom + " " + command, stdin=subprocess.DEVNULL)
        else:
            subprocess.Popen(shlex.split(custom) + [command], stdin=subprocess.DEVNULL)
        return
    if WINDOWS:
        script = STATE.parent / "terminal.cmd"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text("@echo off\r\n" + command + "\r\n")
        subprocess.Popen(["cmd.exe", "/d", "/k", str(script)], creationflags=subprocess.CREATE_NEW_CONSOLE)
        return
    esc = command.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.Popen(["osascript", "-e", 'tell application "Terminal"', "-e", "activate",
                      "-e", 'do script "%s"' % esc, "-e", "end tell"], stdin=subprocess.DEVNULL)


def terminal_auth(method, spec):
    """argv + env for an ACP auth method that wants the client to run a login command in a terminal."""
    meta = (method.get("_meta") or {}).get("terminal-auth")
    if isinstance(meta, dict) and meta.get("command"):
        argv, env = [meta["command"]] + list(meta.get("args") or []), meta.get("env") or {}
    elif method.get("type") == "terminal":
        argv, env = [expand(c) for c in spec["command"]] + list(method.get("args") or []), method.get("env") or {}
    else:
        return None
    argv += [str(a) for a in method.get("loginArgs") or []]
    merged = dict(spec.get("env") or {})
    merged.update(env)
    return argv, merged


def login_variants(methods, spec):
    """Split each terminal login into the config's loginVariants (e.g. Kimi: one button per region).
    An agent that declares no auth method but wants a CLI login first (MiniMax: `mcode acp login`) gets the
    config's terminalLogin as one. The config's authMethods, when set, keeps only those method ids."""
    if spec.get("authMethods"):
        methods = [m for m in methods if m.get("id") in spec["authMethods"]]
    if not methods and spec.get("terminalLogin"):
        methods = [dict(spec["terminalLogin"], type="terminal")]
    variants = spec.get("loginVariants") or []
    out = []
    for m in methods:
        if not variants or not terminal_auth(m, {"command": spec["command"]}):
            out.append(m)
            continue
        for v in variants:
            out.append(dict(m, id="%s:%s" % (m.get("id"), v["id"]), name=v.get("name", v["id"]),
                            description=v.get("description", m.get("description")),
                            loginArgs=[str(a) for a in v.get("args") or []]))
    return out


def load_token():
    """The shared secret the panel sends; created once, readable only by this user."""
    TOKEN_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        fd = os.open(str(TOKEN_FILE), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        token = TOKEN_FILE.read_text().strip()
        if not token:
            raise SystemExit("%s is empty; delete it to generate a new token" % TOKEN_FILE)
        return token
    token = secrets.token_urlsafe(32)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    return token


def descendants(pid):
    """Every process below `pid` (the ACP agent's MCP servers and their children), from one `ps` snapshot."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="], capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    kids = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    found, todo = [], [pid]
    while todo:
        for c in kids.get(todo.pop(), []):
            if c not in found:
                found.append(c)
                todo.append(c)
    return found


def kill_tree(proc, grace=3.0):
    """Stop an agent and everything it started; a plain terminate() would orphan its MCP servers."""
    if proc is None or proc.poll() is not None:
        return
    if WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
    else:
        import signal
        kids = descendants(proc.pid)
        for pid in [proc.pid] + kids:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        try:
            proc.wait(grace)
        except subprocess.TimeoutExpired:
            pass
        for pid in [proc.pid] + kids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        pass


class AcpError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def parse_multipart(content_type, body):
    """[(field name, filename, bytes)] for the file parts of a multipart/form-data body."""
    msg = email.message_from_bytes(b"Content-Type: " + content_type.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body,
                                   policy=email.policy.HTTP)
    out = []
    for part in msg.iter_parts():
        name = part.get_filename()
        if name:
            out.append((part.get_param("name", header="content-disposition"), name, part.get_payload(decode=True) or b""))
    return out


def attached_paths(text):
    i = text.find(ATTACHED)
    if i < 0:
        return []
    paths = []
    for line in text[i + len(ATTACHED):].splitlines():
        line = line.strip()
        if not line:
            continue
        if not line.startswith("- "):
            break
        paths.append(line[2:].strip())
    return paths


def prompt_blocks(text, caps):
    blocks = [{"type": "text", "text": text}]
    images = bool((caps.get("promptCapabilities") or {}).get("image"))
    for path in attached_paths(text):
        if not os.path.isfile(path):
            continue
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if images and mime.startswith("image/") and os.path.getsize(path) <= MAX_IMAGE_BLOCK:
            with open(path, "rb") as f:
                blocks.append({"type": "image", "mimeType": mime, "data": base64.b64encode(f.read()).decode()})
        else:
            blocks.append({"type": "resource_link", "uri": "file://" + urllib.parse.quote(path),
                           "name": os.path.basename(path), "mimeType": mime})
    return blocks


# ---------------------------------------------------------------- sessions

CTX_BLOCK = re.compile(r"^\\?\[REAPER context.*?\\?\[/REAPER context\\?\]\s*", re.S)


def chat_title(text):
    """First line of a message without the panel's REAPER context block (older chats were titled with it)."""
    text = CTX_BLOCK.sub("", (text or "").strip())
    line = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
    return line[:60] or "New chat"


# how to reopen an ACP chat in the agent's own terminal UI ({id} = the ACP session id); spec "resume" overrides
RESUME = {"claude": ["claude", "--resume", "{id}"], "kimi": ["kimi", "--session", "{id}"]}


def brain_path():
    return hibiki_brain.rules_path(BRAIN)


def brain_rules():
    """The user's own rules from rules.md (no header comment, no off / [id] override lines), or ''."""
    return hibiki_brain.effective(BRAIN)["rules"]


def brain_count(text):
    return hibiki_brain.count(text)


def brain_add(rule):
    """Append one line to rules.md; `off: <id>` must name a shipped default (ValueError otherwise)."""
    return hibiki_brain.add(rule, BRAIN)


def brain_info():
    e = hibiki_brain.effective(BRAIN)
    return {"path": e["path"], "exists": e["exists"], "count": e["count"], "defaults": len(e["defaults"]),
            "off": e["off"], "ids": [r["id"] for r in e["defaults"]], "defaults_path": e["defaults_path"],
            "dir": str(BRAIN)}


def brain_sync(cwd):
    """Put the composed rules (Hibiki conventions + rules.md) into cwd's AGENTS.md / CLAUDE.md / GEMINI.md as a marked block; text
    outside the block is the user's and stays."""
    cwd = os.path.abspath(cwd)
    if cwd in (os.path.abspath(os.path.expanduser("~")), os.path.abspath(os.sep)):
        return []  # a block in ~/CLAUDE.md would reach every project under the home folder
    rules = hibiki_brain.compose(BRAIN)
    begin = BRAIN_BEGIN % BRAIN
    changed = []
    for name in BRAIN_FILES:
        path = Path(cwd) / name
        try:
            old = path.read_text(encoding="utf-8") if path.exists() else ""
        except OSError:
            continue
        i = old.find("<!-- hibiki rules: begin")
        j = old.find(BRAIN_END, i) if i >= 0 else -1
        if i >= 0 and j >= 0:
            outside = (old[:i].rstrip("\n"), old[j + len(BRAIN_END):].lstrip("\n"))
        else:
            outside = (old.rstrip("\n"), "")
        block = begin + ("\n" + rules if rules else "") + "\n" + BRAIN_END
        new = "\n\n".join(x for x in (outside[0], block, outside[1]) if x) + "\n"
        if new == old:
            continue
        try:
            tmp = path.with_name(path.name + ".hibiki-tmp")
            tmp.write_text(new, encoding="utf-8")
            os.replace(tmp, path)
            changed.append(name)
        except OSError as e:
            log("brain: cannot write", path, e)
    return changed


class Session:
    def __init__(self, agent, sid=None, title="", created=None):
        self.agent = agent
        self.id = sid or str(uuid.uuid4())
        self.acp_id = None
        self.title = title
        self.created = created or now_iso()
        self.updated = self.created
        self.msgs = []
        self.active = False
        self.cancelled = False
        self.subs = set()
        self.perms = {}  # requestId -> (JSON-RPC id, event)
        self.config = []
        self.backlog = []
        self.error = None  # the last turn's session_error, replayed to clients that subscribe after it
        self.loading = False
        self.lock = threading.RLock()

    def emit(self, kind, **data):
        data["type"] = kind
        with self.lock:
            subs = list(self.subs)
        for q in subs:
            try:
                q.put_nowait(data)
            except queue.Full:  # a client that stopped reading; its SSE loop drops it
                q.dead = True

    def public(self):
        out = {"id": self.id, "name": self.title or "New chat", "isActive": self.active,
               "lastActivityAt": self.updated, "createdAt": self.created}
        resume = self.agent.resume_cmd(self.acp_id)
        if resume:
            out["resume"] = resume
        return out

    def assistant(self):
        if not self.msgs or self.msgs[-1]["type"] != "assistant":
            self.msgs.append({"id": str(uuid.uuid4()), "type": "assistant", "content": {"text": ""},
                              "toolCalls": [], "createdAt": now_iso()})
        return self.msgs[-1]

    def tool_title(self, tool_call_id):
        with self.lock:
            for m in reversed(self.msgs):
                for tc in m.get("toolCalls") or []:
                    if tc.get("id") == tool_call_id:
                        return tc.get("name")
        return None

    def drop_perms(self):
        with self.lock:
            perms, self.perms = self.perms, {}
        for _, ev in perms.values():
            self.emit("permission_resolved", requestId=ev["requestId"])
        return perms

    def persist(self):
        p = STATE / self.agent.slug / (self.id + ".json")
        p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.lock:
            data = json.dumps({"id": self.id, "acp_id": self.acp_id, "title": self.title,
                               "created": self.created, "updated": self.updated, "msgs": self.msgs})
        tmp = p.with_name(p.name + "." + uuid.uuid4().hex[:8] + ".tmp")
        tmp.write_text(data)
        tmp.replace(p)

    def on_update(self, u):
        if self.loading or not isinstance(u, dict):
            return
        kind = u.get("sessionUpdate")
        if kind == "agent_message_chunk":
            c = u.get("content") or {}
            if c.get("type") == "text" and c.get("text"):
                with self.lock:
                    self.assistant()["content"]["text"] += c["text"]
                self.emit("stream_delta", text=c["text"])
        elif kind == "tool_call":
            title = u.get("title") or u.get("kind") or "tool"
            with self.lock:
                self.assistant()["toolCalls"].append({"id": u.get("toolCallId"), "name": title})
            self.emit("tool_use_ready", toolName=title)
        elif kind == "tool_call_update" and u.get("title"):
            with self.lock:
                for tc in self.assistant()["toolCalls"]:
                    if tc.get("id") == u.get("toolCallId"):
                        tc["name"] = u["title"]
        elif kind == "config_option_update" and isinstance(u.get("configOptions"), list):
            self.config = u["configOptions"]
            self.agent.config_cache = self.config
            self.emit("config_options", configOptions=self.config)
        elif kind == "current_mode_update":
            for o in self.config:
                if o.get("category") == "mode":
                    o["currentValue"] = u.get("currentModeId")
            self.emit("config_options", configOptions=self.config)


def normalize_config(result):
    opts = result.get("configOptions")
    if isinstance(opts, list):
        return opts
    out = []
    models = result.get("models")
    if isinstance(models, dict) and models.get("availableModels"):
        out.append({"id": "model", "name": "Model", "category": "model", "type": "select", "_legacy": "model",
                    "currentValue": models.get("currentModelId"),
                    "options": [{"value": m.get("modelId"), "name": m.get("name") or m.get("modelId"),
                                 "description": m.get("description", "")} for m in models["availableModels"]]})
    modes = result.get("modes")
    if isinstance(modes, dict) and modes.get("availableModes"):
        out.append({"id": "mode", "name": "Mode", "category": "mode", "type": "select", "_legacy": "mode",
                    "currentValue": modes.get("currentModeId"),
                    "options": [{"value": m.get("id"), "name": m.get("name") or m.get("id"),
                                 "description": m.get("description", "")} for m in modes["availableModes"]]})
    return out


# ---------------------------------------------------------------- ACP agent process

class AcpAgent:
    def __init__(self, spec, mcp_servers):
        self.spec = spec
        self.slug = ACP_PREFIX + spec["slug"]
        self.name = spec.get("name", spec["slug"])
        self.cwd = os.path.abspath(expand(spec.get("cwd", "~")))
        self.mcp_servers = mcp_servers
        self.proc = None
        self.lock = threading.RLock()      # process lifecycle + request ids
        self.wlock = threading.Lock()      # stdin writes
        self.cfg_lock = threading.Lock()   # warm session / config cache
        self.next_id = 0
        self.pending = {}
        self.state = "stopped"
        self.error = None
        self.connected = False
        self.probing = False
        self.auth_methods = []
        self.caps = {}
        self.sessions = {}
        self.by_acp = {}
        self.config_cache = None  # None = not fetched yet; [] = agent has no options
        self.warm = None
        self.last_used = time.monotonic()
        self.known = {}  # last-known login state, kept across stops and gateway restarts
        self.load_persisted()
        self.load_known()

    def resume_cmd(self, acp_id):
        """Shell line that reopens this chat in the agent's CLI, or None when there is no such CLI here."""
        argv = self.spec.get("resume") or RESUME.get(self.spec["slug"])
        if not acp_id or not argv or not safe_id(acp_id):
            return None
        dirs = [(self.spec.get("env") or {}).get("PATH", ""), os.path.dirname(expand(self.spec["command"][0])),
                expand("~/.local/bin"), os.environ.get("PATH", "")]
        exe = shutil.which(expand(argv[0]), path=os.pathsep.join(d for d in dirs if d))
        if not exe:
            return None
        args = [exe] + [a.replace("{id}", acp_id) for a in argv[1:]]
        # Terminal's PATH lacks the agent's runtime (kimi is `#!/usr/bin/env node`, node lives in ~/.local/node/bin)
        env_path = (self.spec.get("env") or {}).get("PATH")
        try:
            return shell_line(args, cwd=self.cwd, path_prefix=expand(env_path) if env_path else None)
        except ValueError:
            return None

    def known_path(self):
        return STATE / (self.slug + ".status.json")

    def load_known(self):
        try:
            k = json.loads(self.known_path().read_text())
            self.known = k if isinstance(k, dict) else {}
        except (OSError, ValueError):
            self.known = {}

    def remember(self):
        """Record the login state the picker shows while the agent isn't running."""
        k = {"state": "ready" if self.connected else self.state, "connected": self.connected,
             "authMethods": self.auth_methods}
        if k["state"] not in ("ready", "auth_required") or k == self.known:
            return
        self.known = k
        try:
            p = self.known_path()
            p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            tmp = p.with_name(p.name + "." + uuid.uuid4().hex[:8] + ".tmp")
            tmp.write_text(json.dumps(k))
            tmp.replace(p)
        except OSError as e:
            log(self.slug, "could not save status:", e)

    def running(self):
        return self.proc is not None and self.proc.poll() is None

    def installed(self):
        exe = expand(self.spec["command"][0])
        if os.path.isabs(exe):
            return os.path.isfile(exe)
        dirs = [expand((self.spec.get("env") or {}).get("PATH", "")), os.environ.get("PATH", "")]
        return shutil.which(exe, path=os.pathsep.join(d for d in dirs if d)) is not None

    def status(self):
        """What the picker and the login card show; a stopped agent reports its last-known login state."""
        if self.probing:
            return {"state": "starting", "connected": False, "running": self.running(), "error": None,
                    "authMethods": self.auth_methods}
        if self.running() or self.state in ("starting", "authenticating", "auth_required", "error"):
            return {"state": self.state, "connected": self.connected, "running": self.running(), "error": self.error,
                    "authMethods": self.auth_methods}
        if not self.installed():
            return {"state": "error", "connected": False, "running": False, "authMethods": [],
                    "error": "%s is not installed (%s)" % (self.name, self.spec["command"][0])}
        k = self.known
        return {"state": k.get("state") or "stopped", "connected": bool(k.get("connected")), "running": False,
                "error": self.error, "authMethods": self.auth_methods or k.get("authMethods") or []}

    def busy(self):
        """Something still needs the process: a turn, a pending permission, a login, an open stream."""
        if self.probing or self.state in ("starting", "authenticating"):
            return True
        for sess in list(self.sessions.values()) + ([self.warm] if self.warm else []):
            if sess.active or sess.subs or sess.perms:
                return True
        return False

    def stop_if_idle(self, idle):
        with self.lock:
            if not self.running() or self.busy() or time.monotonic() - self.last_used < idle:
                return False
            log(self.slug, "idle for %ds; stopping it (it restarts on the next message)" % idle)
            self.remember()
            proc = self.proc
            self.state, self.connected = "stopped", False
            with self.cfg_lock:
                self.warm = None
            self.by_acp.clear()
        kill_tree(proc)
        return True

    def shutdown(self):
        with self.lock:
            proc = self.proc
        kill_tree(proc)

    def load_persisted(self):
        d = STATE / self.slug
        if not d.is_dir():
            return
        for p in d.glob("*.json"):
            try:
                j = json.loads(p.read_text())
                s = Session(self, p.stem, j.get("title", ""), j.get("created"))
                s.updated = j.get("updated", s.created)
                s.msgs = j.get("msgs") if isinstance(j.get("msgs"), list) else []
                if (s.title or "").lstrip("\\").startswith("[REAPER context"):  # stored cut at 60 chars
                    first = next((m for m in s.msgs if m.get("type") == "user"), None)
                    s.title = chat_title(((first or {}).get("content") or {}).get("text", ""))
                s.acp_id = j.get("acp_id")
            except Exception as e:
                log(self.slug, "skipping", p.name, e)
                continue
            self.sessions[s.id] = s

    # -- process + JSON-RPC
    def ensure(self):
        with self.lock:
            if self.proc and self.proc.poll() is None and self.state not in ("error", "stopped"):
                return
            self.start()

    def _fail_pending(self, message):
        pending, self.pending = self.pending, {}
        for box in pending.values():
            box["error"] = {"code": -1, "message": message}
            box["ev"].set()

    def start(self):
        kill_tree(self.proc)
        self._fail_pending("agent restarted")
        env = dict(os.environ)
        for k, v in (self.spec.get("env") or {}).items():
            env[k] = expand(v)
        cmd = [expand(c) for c in self.spec["command"]]
        os.makedirs(self.cwd, exist_ok=True)
        log("starting", self.slug, cmd)
        self.state, self.error, self.connected = "starting", None, False
        self.by_acp.clear()
        try:
            self.proc = subprocess.Popen(cmd, cwd=self.cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE)
        except OSError as e:
            self.proc, self.state, self.error = None, "error", str(e)
            raise AcpError(-1, "cannot start %s: %s" % (self.name, e))
        threading.Thread(target=self._reader, args=(self.proc,), daemon=True).start()
        threading.Thread(target=self._stderr, args=(self.proc,), daemon=True).start()
        try:
            res = self.request("initialize", {
                "protocolVersion": 1,
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
                "clientInfo": {"name": "hibiki-gateway", "title": "Hibiki gateway", "version": "0.1.0"},
            }, timeout=120)
            if res.get("protocolVersion") != 1:
                raise AcpError(-1, "%s speaks ACP protocol %s, gateway speaks 1" % (self.name, res.get("protocolVersion")))
        except AcpError as e:
            self.state, self.error = "error", e.message
            kill_tree(self.proc)
            raise
        self.caps = res.get("agentCapabilities") or {}
        self.auth_methods = login_variants(res.get("authMethods") or [], self.spec)
        self.state = "ready"

    def _send(self, msg):
        data = (json.dumps(msg) + "\n").encode()
        proc = self.proc
        try:
            with self.wlock:
                proc.stdin.write(data)
                proc.stdin.flush()
        except (AttributeError, OSError, ValueError):
            raise AcpError(-1, self.name + " is not running")

    def request(self, method, params, timeout=None):
        self.last_used = time.monotonic()
        with self.lock:
            self.next_id += 1
            rid = self.next_id
            box = {"ev": threading.Event()}
            self.pending[rid] = box
        try:
            self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        except AcpError:
            self.pending.pop(rid, None)
            raise
        if not box["ev"].wait(timeout):
            self.pending.pop(rid, None)
            raise AcpError(-1, method + " timed out")
        self.last_used = time.monotonic()
        if "error" in box:
            e = box["error"]
            raise AcpError(e.get("code"), e.get("message", "error"))
        return box.get("result") or {}

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def respond(self, rid, result=None, error=None):
        msg = {"jsonrpc": "2.0", "id": rid}
        if error:
            msg["error"] = error
        else:
            msg["result"] = result
        self._send(msg)

    def _reader(self, proc):
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    if not isinstance(msg, dict):
                        raise ValueError("not an object")
                    self._dispatch(msg)
                except Exception as e:  # one bad line must not kill the reader
                    log(self.slug, "bad message:", e, line[:200])
        finally:
            log(self.slug, "exited", proc.poll())
            if proc is self.proc:
                self.state, self.connected = "stopped", False
                self._fail_pending(self.name + " exited")
                for s in list(self.sessions.values()) + ([self.warm] if self.warm else []):
                    s.drop_perms()

    def _dispatch(self, msg):
        self.last_used = time.monotonic()
        if "method" not in msg and "id" in msg:
            box = self.pending.pop(msg["id"], None)
            if box:
                if "error" in msg:
                    box["error"] = msg["error"] if isinstance(msg["error"], dict) else {"message": str(msg["error"])}
                else:
                    box["result"] = msg.get("result")
                box["ev"].set()
        elif "method" in msg and "id" in msg:
            self._on_request(msg)
        elif msg.get("method") == "session/update":
            p = msg.get("params") or {}
            s = self.by_acp.get(p.get("sessionId"))
            if s:
                s.on_update(p.get("update") or {})

    def _stderr(self, proc):
        for line in proc.stderr:
            log(self.slug, "stderr:", line.decode(errors="replace").rstrip()[:300])

    def _on_request(self, msg):
        method, p = msg["method"], msg.get("params") or {}
        if method != "session/request_permission":
            self.respond(msg["id"], error={"code": -32601, "message": "client does not support " + method})
            return
        s = self.by_acp.get(p.get("sessionId"))
        if not s:
            self.respond(msg["id"], {"outcome": {"outcome": "cancelled"}})
            return
        tc = p.get("toolCall") or {}
        title = tc.get("title") or s.tool_title(tc.get("toolCallId")) or tc.get("kind") or "Run tool"
        ev = {"requestId": uuid.uuid4().hex[:8], "title": title, "options": [
            {"optionId": o.get("optionId"), "name": o.get("name"), "kind": o.get("kind")}
            for o in p.get("options") or []]}
        with s.lock:
            s.perms[ev["requestId"]] = (msg["id"], ev)
            s.emit("permission_request", **ev)

    # -- sessions
    def open_session(self, s):
        """Give `s` a fresh ACP session (starting the agent if needed)."""
        self.ensure()
        brain_sync(self.cwd)
        try:
            res = self.request("session/new", {"cwd": self.cwd, "mcpServers": self.mcp_servers}, timeout=180)
        except AcpError as e:
            if e.code == AUTH_REQUIRED:
                self.state, self.connected = "auth_required", False
                self.remember()
            raise
        if not res.get("sessionId"):
            raise AcpError(-1, self.name + " returned no sessionId")
        self.state, self.connected = "ready", True
        self.remember()
        s.acp_id, s.config = res["sessionId"], normalize_config(res)
        self.config_cache = s.config
        self.by_acp[s.acp_id] = s

    def get_config(self):
        with self.cfg_lock:
            if self.config_cache is None:
                w = Session(self)
                self.open_session(w)
                self.warm = w
            return self.config_cache

    def create(self, message, config, title=None):
        with self.cfg_lock:
            s, self.warm = self.warm, None
        if s is None:
            s = Session(self)
            self.open_session(s)
        s.title = chat_title(title or message)
        self.sessions[s.id] = s
        self.send(s, message, config)
        return s

    def revive(self, s):
        """Reattach a session whose ACP side is gone (gateway or agent restarted)."""
        if s.acp_id and s.acp_id in self.by_acp and self.proc and self.proc.poll() is None:
            return
        self.ensure()
        if s.acp_id and self.caps.get("loadSession"):
            brain_sync(self.cwd)
            s.loading = True
            self.by_acp[s.acp_id] = s
            try:
                res = self.request("session/load", {"sessionId": s.acp_id, "cwd": self.cwd,
                                                    "mcpServers": self.mcp_servers}, timeout=180)
                s.config = normalize_config(res) or s.config
                return
            except AcpError as e:
                log(self.slug, "session/load failed:", e.message)
                self.by_acp.pop(s.acp_id, None)
            finally:
                s.loading = False
        self.open_session(s)
        s.emit("notice", text="Started a fresh " + self.name + " session; earlier context is not loaded.")

    def apply_config(self, s, config):
        for cid, value in (config or {}).items():
            opt = next((o for o in s.config if o.get("id") == cid), None)
            if not opt or opt.get("currentValue") == value or value in (None, ""):
                continue
            legacy = opt.get("_legacy")
            if legacy == "model":
                self.request("session/set_model", {"sessionId": s.acp_id, "modelId": value}, timeout=60)
                opt["currentValue"] = value
            elif legacy == "mode":
                self.request("session/set_mode", {"sessionId": s.acp_id, "modeId": value}, timeout=60)
                opt["currentValue"] = value
            else:
                res = self.request("session/set_config_option",
                                   {"sessionId": s.acp_id, "configId": cid, "value": value}, timeout=60)
                if isinstance(res.get("configOptions"), list):
                    s.config = res["configOptions"]
                else:
                    opt["currentValue"] = value
        self.config_cache = s.config or self.config_cache

    def send(self, s, text, config):
        with s.lock:
            s.error = None
            if s.active:
                s.backlog.append((text, config))
                return
            s.active, s.cancelled = True, False
        threading.Thread(target=self._turn, args=(s, text, config), daemon=True).start()

    def _turn(self, s, text, config):
        while True:
            with s.lock:  # before revive, so a failed start still keeps the message in the transcript
                s.msgs.append({"id": str(uuid.uuid4()), "type": "user", "content": {"text": text},
                               "createdAt": now_iso()})
                s.updated = now_iso()
            try:
                self.revive(s)
                try:
                    self.apply_config(s, config)
                except AcpError as e:  # a stale pick must not cost the message
                    s.emit("notice", text="Kept the previous settings: " + e.message)
                s.emit("session_active")
                if not s.cancelled:
                    res = self.request("session/prompt", {"sessionId": s.acp_id,
                                                          "prompt": prompt_blocks(text, self.caps)})
                    if res.get("stopReason") not in (None, "end_turn", "cancelled"):
                        s.emit("notice", text="Stopped: " + str(res.get("stopReason")))
            except Exception as e:
                code, message = (e.code, e.message) if isinstance(e, AcpError) else (-1, repr(e))
                if code == AUTH_REQUIRED:
                    self.state, self.connected = "auth_required", False
                    self.remember()
                if s.backlog:
                    message += " (%d queued message%s not sent)" % (len(s.backlog), "" if len(s.backlog) == 1 else "s")
                with s.lock:
                    s.active = False
                    for queued, _ in s.backlog:  # kept in the transcript so the user can see and resend them
                        s.msgs.append({"id": str(uuid.uuid4()), "type": "user", "content": {"text": queued},
                                       "createdAt": now_iso()})
                    s.backlog.clear()
                    s.updated = now_iso()
                    s.error = {"apiErrorCode": "auth_required" if code == AUTH_REQUIRED else "acp_error",
                               "errorPresentation": {"message": self.name + ": " + message}}
                s.drop_perms()
                self._save(s)
                s.emit("session_error", **s.error)
                return
            s.drop_perms()
            with s.lock:
                s.updated = now_iso()
                nxt = s.backlog.pop(0) if s.backlog else None
                if nxt is None:
                    s.active = False
                else:
                    s.cancelled = False
            self._save(s)
            if nxt is None:
                s.emit("session_idle")
                return
            text, config = nxt

    def _save(self, s):
        try:
            s.persist()
        except OSError as e:
            log(self.slug, "could not save transcript:", e)

    def interrupt(self, s):
        with s.lock:
            s.backlog.clear()
            s.cancelled = s.active
        for rid, _ in s.drop_perms().values():
            try:
                self.respond(rid, {"outcome": {"outcome": "cancelled"}})
            except AcpError:
                pass
        if s.acp_id and self.proc and self.proc.poll() is None:
            self.notify("session/cancel", {"sessionId": s.acp_id})

    def answer(self, s, request_id, option_id):
        with s.lock:
            item = s.perms.pop(request_id, None)
        if not item:
            return False
        rid, _ = item
        if option_id:
            self.respond(rid, {"outcome": {"outcome": "selected", "optionId": option_id}})
        else:
            self.respond(rid, {"outcome": {"outcome": "cancelled"}})
        s.emit("permission_resolved", requestId=request_id)
        return True

    def save_upload(self, filename, data):
        d = os.path.join(self.cwd, "uploads")
        os.makedirs(d, exist_ok=True)
        safe = re.sub(r"[^\w.\- ]+", "_", os.path.basename(filename)).strip() or "file"
        path = os.path.join(d, time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6] + "-" + safe)
        with open(path, "wb") as f:
            f.write(data)
        return {"success": True, "path": path, "filename": filename, "size": len(data)}

    def probe(self):
        """Start the agent and open a warm session so the picker knows whether it is logged in."""
        with self.lock:
            if self.probing or self.connected or self.state not in ("stopped", "ready", "error"):
                return False
            self.probing = True
        threading.Thread(target=self._probe, daemon=True).start()
        return True

    def _probe(self):
        try:
            self.get_config()
        except Exception as e:  # surfaced through state/error
            if self.state != "auth_required":
                self.error = str(e)
        finally:
            self.probing = False

    def authenticate(self, method_id):
        method = next((m for m in self.auth_methods if m.get("id") == method_id), {})
        term = terminal_auth(method, self.spec)
        if term:
            return self.terminal_login(*term)
        try:
            self.ensure()
            self.state = "authenticating"
            self.request("authenticate", {"methodId": method_id}, timeout=900)
            self.state, self.error, self.connected = "ready", None, True
            self.remember()
        except AcpError as e:
            self.state, self.error = "auth_required", e.message

    def terminal_login(self, argv, env):
        """Open the agent's login command in a terminal, then retry a session until the login lands."""
        self.state, self.error = "authenticating", None
        try:
            open_terminal(shell_line(argv, env={k: expand(v) for k, v in env.items()}))
        except (OSError, ValueError) as e:
            self.state, self.error = "auth_required", "cannot open a terminal: %s" % e
            return
        deadline = time.time() + LOGIN_TIMEOUT
        while time.time() < deadline:
            time.sleep(LOGIN_POLL)
            try:
                with self.cfg_lock:
                    self.config_cache = None
                self.get_config()
                return
            except AcpError as e:
                if e.code != AUTH_REQUIRED:
                    self.state, self.error = "auth_required", e.message
                    return
                self.state = "authenticating"
        self.state, self.error = "auth_required", "login timed out"


# ---------------------------------------------------------------- Gamut model selector

EFFORTS = ["low", "medium", "high", "xhigh", "max"]


def gamut_json(path, timeout=10):
    with urllib.request.urlopen(GAMUT + path, timeout=timeout) as r:
        return json.load(r)


def gamut_defaults(slug):
    """What the agent runs with when nothing is picked: its own preferences, else Gamut's global defaults."""
    prefs, glob = {}, {}
    try:
        prefs = gamut_json("/api/agents/%s/preferences" % urllib.parse.quote(slug, safe="")) or {}
    except (urllib.error.URLError, OSError, ValueError):
        pass
    try:
        glob = (gamut_json("/api/settings") or {}).get("models") or {}
    except (urllib.error.URLError, OSError, ValueError):
        pass
    return (prefs.get("defaultLlmProviderId"), prefs.get("defaultModel") or glob.get("agentModel"),
            prefs.get("defaultEffort") or glob.get("agentEffort"))


def resolve_model(conns, conn_id, model):
    """'<connectionId>|<modelId>' for a model id or family alias ("opus" = the family's newest entry)."""
    if not model:
        return None
    for c in [c for c in conns if c.get("id") == conn_id] or conns:
        cat = c.get("catalog") or []
        for m in cat:
            if m.get("id") == model:
                return c["id"] + "|" + m["id"]
        family = [m for m in cat if m.get("family") == model]
        if family:
            return c["id"] + "|" + family[-1]["id"]
    return None


def gamut_config(slug=None):
    """Gamut's model catalog as ACP-style config options; value = '<connectionId>|<modelId>'.
    currentValue is what the agent uses when nothing is picked, so the panel can show it."""
    conns = gamut_json("/api/llm-connections").get("connections") or []
    conn_id, model_default, effort_default = gamut_defaults(slug) if slug else (None, None, None)
    models = []
    for c in conns:
        for m in c.get("catalog") or []:
            models.append({"value": c["id"] + "|" + m["id"], "name": m.get("label") or m["id"],
                           "group": c.get("name", ""), "efforts": m.get("supportedEfforts") or []})
    seen = {e for m in models for e in m["efforts"]}
    efforts = [e for e in EFFORTS if e in seen]
    out = [{"id": "model", "name": "Model", "category": "model", "type": "select",
            "currentValue": resolve_model(conns, conn_id, model_default),
            "options": [{"value": "", "name": "Agent default"}] + models}]
    if efforts:
        out.append({"id": "effort", "name": "Effort", "category": "thought_level", "type": "select",
                    "currentValue": effort_default if effort_default in efforts else None,
                    "options": [{"value": "", "name": "Default"}] + [{"value": e, "name": e} for e in efforts]})
    return out


def gamut_body(body):
    body.pop("title", None)  # the panel's title hint is for ACP sessions; Gamut names its own
    cfg = body.pop("config", None)
    cfg = cfg if isinstance(cfg, dict) else {}
    model = cfg.get("model")
    if isinstance(model, str) and model:
        conn, _, mid = model.partition("|")
        body["llmProviderId"], body["model"] = conn, mid
    if cfg.get("effort"):
        body["effort"] = cfg["effort"]
    return body


# ---------------------------------------------------------------- Hibiki: installs and Gamut's REAPER MCP

def suite():
    """reaper_mcp.suite from the same tree (clone or installed app): one implementation for the CLI and the panel."""
    root = str(Path(__file__).resolve().parents[1])
    if root not in sys.path:
        sys.path.insert(0, root)
    from reaper_mcp import suite as s
    return s


class Installs:
    """`hibiki agents add <key>` run in the background for the panel's Install button; one at a time."""

    def __init__(self, run=None):
        self.state = {}  # key -> {"state": "installing" | "done" | "error", "error": str}
        self.lock = threading.Lock()
        self.run = run or (lambda key: suite().agents_add(suite().Paths(), [key], restart=False))

    def start(self, key, on_done):
        with self.lock:
            if any(v["state"] == "installing" for v in self.state.values()):
                return False
            self.state[key] = {"state": "installing", "error": ""}

        def work():
            try:
                self.run(key)
                on_done()
                self.state[key] = {"state": "done", "error": ""}
            except BaseException as e:  # agents_add raises SystemExit on a failed download check
                log("install", key, "failed:", repr(e))
                self.state[key] = {"state": "error", "error": str(e) or repr(e)}

        threading.Thread(target=work, daemon=True).start()
        return True


# ---------------------------------------------------------------- HTTP

def mcp_specs(cfg):
    return [{"name": m["name"], "command": expand(m["command"]), "args": [expand(a) for a in m.get("args", [])],
             "env": [{"name": k, "value": expand(v)} for k, v in (m.get("env") or {}).items()]}
            for m in cfg.get("mcpServers", [])]


def messages_after(msgs, after):
    """The panel's incremental refresh: messages strictly after `after`, or all of them if it isn't there."""
    for i, m in enumerate(msgs):
        if isinstance(m, dict) and m.get("id") == after:
            return {"after": after, "messages": msgs[i + 1:]}
    return {"full": True, "messages": msgs}


class Gateway:
    def __init__(self):
        self.token = load_token()
        self.acp = {}
        self.installs = Installs()
        self.requests = threading.BoundedSemaphore(MAX_REQUESTS)
        self.streams = threading.BoundedSemaphore(MAX_STREAMS)
        self.reload()

    def reap_idle(self, idle=None):
        stopped = []
        for a in list(self.acp.values()):
            try:
                if a.stop_if_idle(IDLE_STOP if idle is None else idle):
                    stopped.append(a.slug)
            except Exception as e:
                log(a.slug, "idle check failed:", repr(e))
        return stopped

    def reaper(self):
        while True:
            time.sleep(IDLE_CHECK)
            self.reap_idle()

    def shutdown(self):
        for a in list(self.acp.values()):
            a.shutdown()

    def reload(self):
        """Pick up ACP agents added to the config (by an install) without restarting; running ones stay as they are."""
        cfg = load_config()
        mcp = mcp_specs(cfg)
        for spec in cfg.get("acp", []):
            if ACP_PREFIX + spec["slug"] not in self.acp:
                a = AcpAgent(spec, mcp)
                self.acp[a.slug] = a


GW = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 60  # header and body reads; a stalled client can't hold a thread forever

    def log_message(self, fmt, *args):
        if os.environ.get("AGENT_GATEWAY_DEBUG"):
            log(fmt % args)

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(data)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def refuse(self, n):
        """Only local, non-browser clients: no Origin, a host name we expect, JSON bodies. Headers only: the body
        isn't read until the request is known to be allowed."""
        if self.headers.get("Origin") is not None:
            return "browser requests are not accepted"
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        if host not in ALLOWED_HOSTS:
            return "unexpected Host"
        if self.path.split("?", 1)[0] != "/health" and not hmac.compare_digest(
                (self.headers.get("Authorization") or "").encode(), ("Bearer " + GW.token).encode()):
            return "missing or wrong gateway token (%s)" % TOKEN_FILE
        ctype = self.headers.get("Content-Type") or ""
        upload = self.path.split("?", 1)[0].endswith("/upload-file")
        if n > 0 and "json" not in ctype and not (upload and ctype.startswith("multipart/form-data")):
            return "JSON body required"
        return None

    def route(self, method):
        self.raw, self.json = b"", {}
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        why = self.refuse(max(n, 0))
        if why:
            return self.reply(403, {"error": why})
        if not 0 <= n <= MAX_UPLOAD:
            return self.reply(413, {"error": "bad or too large Content-Length"})
        path = self.path.split("?", 1)[0]  # acp_route reads the query (?probe=1) from self.path
        sem = GW.streams if method == "GET" and path.endswith("/stream") else GW.requests
        if not sem.acquire(blocking=False):
            return self.reply(503, {"error": "too many requests in flight"})
        try:
            self.raw = self.rfile.read(n) if n > 0 else b""
            try:
                self.json = json.loads(self.raw) if self.raw else {}
            except ValueError:
                self.json = {}
            if not isinstance(self.json, dict):
                self.json = {}
            return self.dispatch(method, path)
        finally:
            sem.release()

    def dispatch(self, method, path):
        parts = [p for p in path.split("/") if p]
        try:
            if not path.startswith("/"):
                return self.reply(400, {"error": "bad path"})
            if path == "/health":
                return self.reply(200, {"ok": True})
            if method == "GET" and parts == ["api", "agents"]:
                return self.agents()
            if parts[:2] == ["api", "hibiki"]:
                return self.hibiki(method, parts[2:])
            if parts[:2] == ["api", "agents"] and len(parts) >= 3:
                if not safe_id(parts[2]) or (len(parts) >= 5 and parts[3] == "sessions" and not safe_id(parts[4])):
                    return self.reply(400, {"error": "bad agent or session id"})
                slug, rest = parts[2], parts[3:]
                if slug in GW.acp:
                    return self.acp_route(method, GW.acp[slug], rest)
                if method == "GET" and rest == ["config"]:
                    return self.reply(200, {"configOptions": gamut_config(slug)})
                if method == "GET" and len(rest) == 3 and rest[0] == "sessions" and rest[2] == "messages" \
                        and self.query("after") is not None:
                    return self.gamut_messages_after(path, self.query("after"))
            return self.proxy(method, path)
        except AcpError as e:
            code = 401 if e.code == AUTH_REQUIRED else 502
            return self.reply(code, {"error": "auth_required" if code == 401 else e.message, "message": e.message})
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            return None
        except (urllib.error.URLError, OSError) as e:
            return self.reply(502, {"error": "Gamut not reachable: " + str(e)})
        except Exception as e:
            log("unhandled", method, self.path, repr(e))
            try:
                return self.reply(500, {"error": repr(e)})
            except OSError:
                return None

    def query(self, name):
        vals = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query, keep_blank_values=True).get(name)
        return vals[0] if vals else None

    def gamut_messages_after(self, path, after):
        q = [(k, v) for k, v in urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query, keep_blank_values=True)
             if k != "after"]
        url = GAMUT + path + ("?" + urllib.parse.urlencode(q) if q else "")
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            body = e.read()
            try:
                return self.reply(e.code, json.loads(body))
            except ValueError:
                return self.reply(e.code, {"error": body.decode(errors="replace")[:300]})
        msgs = data.get("messages") if isinstance(data, dict) else data
        if not isinstance(msgs, list):
            return self.reply(502, {"error": "Gamut returned no message list"})
        return self.reply(200, messages_after(msgs, after))

    def agents(self):
        out = []
        try:
            g = gamut_json("/api/agents", timeout=5)
            g = g.get("agents", []) if isinstance(g, dict) else g
            out = [a for a in g if isinstance(a, dict)] if isinstance(g, list) else []
            for a in out:
                a.setdefault("backend", "gamut")
        except (urllib.error.URLError, OSError, ValueError) as e:
            log("gamut unreachable:", e)
        for a in GW.acp.values():
            out.append({"slug": a.slug, "name": a.name, "description": a.spec.get("description", ""),
                        "backend": "acp"})
        self.reply(200, out)

    def hibiki(self, method, rest):
        if rest == ["installable"] and method == "GET":
            out = []
            for key, a in suite().ACP_AGENTS.items():
                st = GW.installs.state.get(key, {})
                out.append({"key": key, "slug": ACP_PREFIX + key, "name": a["name"], "description": a["description"],
                            "installed": ACP_PREFIX + key in GW.acp, "state": st.get("state", ""), "error": st.get("error", "")})
            return self.reply(200, out)
        if rest == ["install"] and method == "POST":
            key = self.json.get("agent")
            if key not in suite().ACP_AGENTS:
                return self.reply(400, {"error": "unknown agent"})
            if not GW.installs.start(key, GW.reload):
                return self.reply(409, {"error": "another install is running"})
            return self.reply(202, {"state": "installing"})
        if rest == ["gamut-reaper"]:
            s = suite()
            if method == "GET":
                slug = self.query("agent") or ""
                if slug and not safe_id(slug):
                    return self.reply(400, {"error": "bad agent id"})
                return self.reply(200, {"registered": bool(s.gamut_reaper_id()),
                                        "enabled": bool(slug) and s.gamut_reaper_enabled(slug)})
            if method == "POST" and self.json.get("agent"):
                if not safe_id(self.json["agent"]):
                    return self.reply(400, {"error": "bad agent id"})
                return self.reply(200, {"status": s.gamut_enable(s.Paths(), self.json["agent"])})
        if rest == ["brain"]:
            if method == "POST" and self.json.get("ensure") is True:
                hibiki_brain.ensure(BRAIN)
                return self.reply(200, brain_info())
            if method == "POST":
                try:
                    added = brain_add(self.json.get("add"))
                except ValueError as e:
                    return self.reply(400, {"error": str(e)})
                for a in GW.acp.values():
                    brain_sync(a.cwd)
                return self.reply(200, dict(brain_info(), added=added))
            if method == "GET":
                return self.reply(200, dict(brain_info(), chars=len(hibiki_brain.compose(BRAIN)), max=BRAIN_MAX,
                                            folders=sorted({a.cwd for a in GW.acp.values()})))
        return self.reply(404, {"error": "unknown hibiki route"})

    def acp_route(self, method, a, rest):
        b = self.json
        if method == "GET" and rest == ["status"]:
            probe = self.query("probe")
            if probe in (a.slug, a.spec["slug"]):
                a.probe()
            return self.reply(200, a.status())
        if method == "POST" and rest == ["auth"]:
            threading.Thread(target=a.authenticate, args=(b.get("methodId"),), daemon=True).start()
            return self.reply(202, {"state": "authenticating"})
        if method == "GET" and rest == ["config"]:
            return self.reply(200, {"configOptions": a.get_config()})
        if method == "POST" and rest[-1:] == ["upload-file"] and (len(rest) == 1 or rest[0] == "sessions"):
            files = parse_multipart(self.headers.get("Content-Type") or "", self.raw)
            f = next((x for x in files if x[0] == "file"), files[0] if files else None)
            if not f:
                return self.reply(400, {"error": "No file provided"})
            return self.reply(200, a.save_upload(f[1], f[2]))
        if rest == ["sessions"]:
            if method == "GET":
                ss = sorted(a.sessions.values(), key=lambda s: s.updated, reverse=True)
                return self.reply(200, [s.public() for s in ss])
            if method == "POST":
                msg = str(b.get("message") or "").strip()
                if not msg:
                    return self.reply(400, {"error": "Message is required"})
                title = b.get("title") if isinstance(b.get("title"), str) else None
                return self.reply(201, a.create(msg, b.get("config"), title).public())
        if len(rest) >= 2 and rest[0] == "sessions":
            s = a.sessions.get(rest[1])
            if not s:
                return self.reply(404, {"error": "Session not found"})
            tail = rest[2:]
            if method == "GET" and tail == []:
                return self.reply(200, s.public())
            if method == "GET" and tail == ["messages"]:
                with s.lock:
                    msgs = list(s.msgs)
                after = self.query("after")
                return self.reply(200, msgs if after is None else messages_after(msgs, after))
            if method == "POST" and tail == ["messages"]:
                text = str(b.get("content") or "").strip()
                if not text:
                    return self.reply(400, {"error": "Content is required"})
                a.send(s, text, b.get("config"))
                return self.reply(200, {"ok": True})
            if method == "GET" and tail == ["stream"]:
                return self.sse(s)
            if method == "POST" and tail == ["interrupt"]:
                a.interrupt(s)
                return self.reply(200, {"ok": True})
            if method == "POST" and tail == ["permission"]:
                ok = a.answer(s, b.get("requestId"), b.get("optionId"))
                return self.reply(200 if ok else 404, {"ok": ok})
        return self.reply(404, {"error": "not found"})

    def sse(self, s):
        q = queue.Queue(SSE_QUEUE_MAX)
        q.dead = False
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.connection.settimeout(30)  # a client that stops reading can't pin this thread forever

        def write(d):
            self.wfile.write(("event: message\ndata: " + json.dumps(d) + "\n\n").encode())
            self.wfile.flush()

        with s.lock:  # subscribe and snapshot together so nothing is missed or doubled
            s.subs.add(q)
            pending = [ev for _, ev in s.perms.values()]
            active = s.active
            # a client that subscribes after the turn started (the panel creates the session, then subscribes)
            # gets the reply so far; "connected" with isActive tells it to rebuild its live view from this
            turn = s.msgs[-1] if active and s.msgs and s.msgs[-1]["type"] == "assistant" else None
            replay_text = turn["content"]["text"] if turn else ""
            replay_tools = [tc.get("name") for tc in turn.get("toolCalls") or []] if turn else []
            error = None if active else s.error
        try:
            write({"type": "connected", "isActive": active})
            for name in replay_tools:
                write({"type": "tool_use_ready", "toolName": name})
            if replay_text:
                write({"type": "stream_delta", "text": replay_text})
            for ev in pending:
                write(dict(ev, type="permission_request"))
            if error:
                write(dict(error, type="session_error"))
            while not q.dead:
                try:
                    d = q.get(timeout=15)
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                write(d)
        except (OSError, socket.timeout):
            pass
        finally:
            with s.lock:
                s.subs.discard(q)

    def proxy(self, method, path):
        body = self.raw or None
        if body and method == "POST" and "/sessions" in path and self.json:
            body = json.dumps(gamut_body(dict(self.json))).encode()
        stream = path.endswith("/stream")
        # Gamut answers a send only once the agent has the message; waking a long idle session can take minutes
        send = method == "POST" and (path.endswith("/sessions") or path.endswith("/messages"))
        req = urllib.request.Request(GAMUT + self.path, data=body, method=method)
        for h in ("Content-Type", "Accept"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            resp = urllib.request.urlopen(req, timeout=None if stream else 300 if send else 60)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(data)
            return
        ctype = resp.headers.get("Content-Type", "")
        if "text/event-stream" in ctype:
            self.send_response(resp.status)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                while True:
                    line = resp.readline()  # HTTPResponse.readline decodes chunked transfer encoding
                    if not line:
                        break
                    self.wfile.write(line)
                    if line in (b"\n", b"\r\n"):
                        self.wfile.flush()
            finally:
                resp.close()
            return
        data = resp.read()
        self.send_response(resp.status)
        self.send_header("Content-Type", ctype or "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(data)


def main():
    global GW
    GW = Gateway()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    threading.Thread(target=GW.reaper, daemon=True).start()

    def stop(*_):
        GW.shutdown()  # the agents and their MCP servers go with the gateway
        os._exit(0)
    import signal
    for sig in ("SIGTERM", "SIGINT", "SIGHUP"):
        if hasattr(signal, sig):
            try:
                signal.signal(getattr(signal, sig), stop)
            except (OSError, ValueError):
                pass
    log("agent gateway on 127.0.0.1:%d, gamut %s, acp: %s" % (PORT, GAMUT, ", ".join(GW.acp) or "none"))
    srv.serve_forever()


if __name__ == "__main__":
    main()
