# Hibiki

<img src="icons/hibiki.svg" alt="" width="96" height="96" align="left" hspace="12" vspace="4">

**Hibiki is the agent inside your music editor, built for professionals.** Talk to it about what you're working on, let it edit, arrange
and mix alongside you, and bring the AI agents you already use. It runs in [REAPER](https://reaper.fm) today.<br clear="left">

<p align="center"><img src="docs/demo/hibiki-demo.webp" alt="Hibiki in REAPER: asking the agent to brighten the pizzicato from bar 51 and put it in the kick sidechain" width="960"></p>
<p align="center"><sub>A real request and the agent's real replies, replayed over a recreated REAPER window. <a href="docs/demo/hibiki-demo.mp4">Full video (MP4)</a></sub></p>

| Path | What |
| --- | --- |
| `reaper_mcp/` | MCP server (`server.py` stdio, `http_server.py` bearer HTTP) + `bridge.lua`, the Lua bridge that runs inside REAPER |
| `panel/` | Hibiki — chat panel docked in REAPER (ReaImGui) for Gamut, Codex and other ACP agents |
| `reaper/__startup.lua` | Starts the bridge and the chat panel whenever REAPER launches |
| `gateway/` | Agent gateway: one local API for the panel in front of Gamut and ACP agents (Codex, …) |
| `scripts/` | Remote-host bootstrap (Cloudflare Tunnel) and hot-swap deploy of the bridge — see `docs/remote-host.md` |

[![ci](https://github.com/yiw190/hibiki/actions/workflows/ci.yml/badge.svg)](https://github.com/yiw190/hibiki/actions/workflows/ci.yml)

```
MCP client  --stdio JSON-RPC-->  reaper_mcp/server.py  --JSON mailbox-->  reaper_mcp/bridge.lua (inside REAPER)
```

Fourteen grouped tools. Multi-step edits go through `batch`; anything else through `reaper_call` / `run_lua`. Track index `-1` is the master. Time is project quarter notes. Call `status` first; on a new project pass `detail=true` for arrangement facts (time signature, length in beats, markers, MIDI vs audio) — not chords. `midi cc` is CC and program change; `item import` takes a path on the REAPER host; `project save` writes without a dialog (pass `path` if the project is unsaved). `midi get` omits default fields; `batch` slots are the inner result or `{error}`.

**Just want the MCP?** For Claude Desktop, Claude Code or Cursor with no panel, no gateway and no background
services, see [MCP only](#mcp-only).

## Install (macOS)

1. **REAPER first.** Download it from [reaper.fm](https://www.reaper.fm/download.php), drag it to Applications and
   open it once. The package (and `hibiki setup`) refuses to install on a Mac without REAPER.
2. **Hibiki.** Download `Hibiki-<version>.pkg` from [Releases](https://github.com/yiw190/hibiki/releases) and open it.
   The package brings its own Python, so it doesn't need the Xcode command line tools. To upgrade, install a newer
   package.
3. **Restart REAPER.** The Hibiki panel opens docked on the right; click the agent name at its top to pick a provider
   and model.
4. **Connect an agent** — Gamut or a CLI agent: see [Connect an agent](#connect-an-agent-step-4).

The package isn't signed yet. If macOS says it can't verify the developer, open **System Settings → Privacy & Security**
and click **Open Anyway**.

What it sets up for the logged-in user (`hibiki setup` runs the same steps; safe to re-run):

| Piece | Where |
| --- | --- |
| Lua bridge, Hibiki panel | `<REAPER resource path>/Scripts/reaper_mcp_bridge.lua`, `Scripts/Hibiki/` |
| ReaImGui (if missing, pinned + sha256-checked), and its `imgui.lua` shim | `<REAPER resource path>/UserPlugins/`, `Scripts/ReaTeam Extensions/API/` |
| Startup hook: starts both with REAPER | a marked block in `Scripts/__startup.lua`; your own lines stay |
| MCP over HTTP on `127.0.0.1:8787` (bearer in `~/.config/reaper-mcp/token`, 0600) | LaunchAgent `com.hibiki.reaper-mcp` |
| Agent gateway on `127.0.0.1:47892` | LaunchAgent `com.hibiki.agent-gateway` |
| MCP registration | Gamut (as **REAPER**), plus Claude Desktop, Claude Code and Cursor when they're installed |

```bash
hibiki doctor                         # what's installed, what's running, what's wrong
hibiki recover                        # restart the MCP + gateway, drop stuck panel streams (REAPER untouched)
hibiki connect gamut|claude-desktop|claude-code|cursor [--remove]
hibiki agents add codex claude kimi   # ACP agents for the panel (Node goes in ~/.local/node)
hibiki watchdog on|off                # relaunch REAPER after crashes, for an unattended Mac
hibiki stop                           # turn the background services off; they stay off after login
hibiki start                          # turn them back on (setup does too)
hibiki update                         # newer release on GitHub? (--channel stable|dev, --json; dev builds default to dev)
hibiki update --install               # download it, verify its sha256, open the installer (you finish it); source clones: git pull
hibiki uninstall [--purge]            # --purge also deletes tokens and gateway config
hibiki use dev [--path ~/reaper-mcp]  # testing unreleased code: run everything from a git checkout (no admin)
hibiki use release                    # back to the installed package
hibiki use [status] [--json]          # which one is live: release version, or checkout path @ commit
```

`hibiki use dev` records the checkout in `~/.config/reaper-mcp/mode.json` and runs the checkout's `setup` with the
package's Python, so the LaunchAgents, the bridge and the panel come from the checkout; every `hibiki` command
(including the panel's Recover and update) then runs the checkout's code. Restart REAPER to load the new bridge and
panel. `hibiki update --install` refuses in dev mode, and installing a package switches back to release.

From a clone instead (the LaunchAgents then run from the clone, so keep it; re-run after `git pull`):

```bash
git clone https://github.com/yiw190/hibiki.git ~/hibiki
sh ~/hibiki/install.sh                # WITH_AGENTS=1 also adds Codex, Claude Code and Kimi
```

## Install (Windows)

Release candidate: tested in CI on Windows Server, not yet on a desktop REAPER. Windows 10 1803+ (64-bit).

1. **REAPER first.** Download the 64-bit installer from [reaper.fm](https://www.reaper.fm/download.php), install it and
   open REAPER once. The installer (and `hibiki setup`) refuses to install on a PC without REAPER.
2. **Hibiki.** Download `Hibiki-<version>-setup.exe` from [Releases](https://github.com/yiw190/hibiki/releases) and run
   it. It installs for your Windows user only (`%LOCALAPPDATA%\Programs\Hibiki`, no administrator rights), brings its
   own Python and adds `hibiki` to your PATH. To upgrade, run a newer installer; to remove, use **Settings → Apps**.
3. **Restart REAPER.** Same as on macOS: the panel opens docked on the right.
4. **Connect an agent** — see [Connect an agent](#connect-an-agent-step-4).

The installer isn't signed yet: if SmartScreen stops it, click **More info → Run anyway**.

Differences from macOS: the REAPER resource path is `%APPDATA%\REAPER`; instead of LaunchAgents one background
supervisor (`hibiki run`, windowless) keeps the MCP and the gateway running, started at logon from
`HKCU\...\CurrentVersion\Run`; logs are in `%LOCALAPPDATA%\Hibiki\logs`; **Open in Claude Code / Kimi** opens a
`cmd` window; the watchdog is macOS only. From a clone: `py -m reaper_mcp setup` (Python 3.9+).

## Connect an agent (step 4)

The panel talks to an agent; Hibiki doesn't ship one. Pick either route — or both, they show up side by side in the
panel's **Agent settings → Provider**.

**Route A — Gamut** (desktop app, agents with skills, dashboards, connected accounts):

1. Download Gamut — [macOS (Apple Silicon)](https://updates.gamutagents.com/download/mac) ·
   [Windows](https://updates.gamutagents.com/download/win) · [all releases](https://github.com/SkillfulAgents/SuperAgent/releases/latest)
   ([source](https://github.com/SkillfulAgents/SuperAgent), [gamut.so](https://www.gamut.so)).
2. Open it and sign in with your Gamut account. Gamut sets up its own agent containers and models; your own API keys
   (Anthropic, OpenRouter, Bedrock, OpenAI) are optional.
3. Create an agent.
4. In the Hibiki panel pick **Gamut** and the agent under **Agent details**. Gamut gives MCP servers to agents one by
   one, so the panel offers **Enable REAPER for <agent>** until that agent has it (one click; it also registers the
   MCP in Gamut if setup ran before Gamut was installed). From a terminal instead:
   `hibiki connect gamut --agent "<name>"` (or `--all-agents`, or no flag to pick from a list).

**Route B — a coding-agent CLI** (each uses its own login / subscription): click **Install** next to it on the panel's
"Connect an agent" card or in **Agent settings → Provider** — it installs Node and the CLI into `~/.local/node` (no admin
rights) and loads it without a restart — then **Connect** to log in once. The REAPER MCP is wired in automatically.

| Agent | Package | Login |
| --- | --- | --- |
| Claude Code | `@agentclientprotocol/claude-agent-acp` | your Claude login |
| Codex | `@agentclientprotocol/codex-acp` | ChatGPT / OpenAI |
| Kimi | `@moonshot-ai/kimi-code` | kimi.ai or kimi.com (one button each) |
| MiniMax | `@minimax-ai/code` | global or mainland account (one button each) |
| Grok | `@xai-official/grok` | browser sign-in; SuperGrok or X Premium+ (beta) |
| Gemini | `@google/gemini-cli` | Google sign-in in the browser; Google AI Pro / Ultra |
| Copilot | `@github/copilot` | `copilot login` (device code) in Terminal; Copilot Pro / Pro+ |

Same from a terminal: `hibiki agents add claude kimi minimax grok gemini copilot codex`. Not one-click yet: Qwen Code (ACP only offers
an OpenAI-compatible API key set through environment variables) and DeepSeek (its harness's ACP server is
automation-only; DeepSeek models work through an ACP agent such as OpenCode with an API key).

## MCP only

On macOS or Windows, from a clone:

```bash
git clone https://github.com/yiw190/hibiki.git ~/hibiki
sh ~/hibiki/install.sh --mcp-only     # Windows: python -m reaper_mcp setup --mcp-only
```

What it does:

- Installs the bridge and a startup hook that starts it with REAPER.
- Registers the MCP in Claude Desktop, Claude Code and Cursor, if they're installed.
- Nothing else: no panel, no background services, no token.

Keep the cloned folder: those apps run `reaper_mcp/server.py` from it. Check the install with
`hibiki doctor --mcp-only`.

Gamut needs the full install instead: it reaches REAPER through the background HTTP service, which this mode leaves out.

For other MCP clients or operating systems, see the next section.

## Manual setup (any MCP client, any OS)

```bash
python3 -m reaper_mcp install-bridge
```

Then in REAPER: **Actions → Load ReaScript → `reaper_mcp_bridge.lua` → Run**. It starts silently (no console window); `hibiki doctor` shows the bridge version and heartbeat. Set `REAPER_MCP_DEBUG=1` to log to the ReaScript console.

MCP client config (any client that runs stdio servers):

```json
{
  "mcpServers": {
    "reaper": {
      "command": "python3",
      "args": ["/absolute/path/to/hibiki/reaper_mcp/server.py"]
    }
  }
}
```

On Windows use native Python, not WSL (they don't share the mailbox).

```
REAPER_MCP_IPC_DIR     mailbox override (must match on both sides)
REAPER_MCP_TIMEOUT     default 10s
REAPER_MCP_DEBUG=1     Lua request log
```

Mailbox: `~/Library/Application Support/reaper-mcp/ipc` on macOS, `%APPDATA%/reaper-mcp/ipc` on Windows,
`$XDG_DATA_HOME/reaper-mcp/ipc` on Linux. Time is **beats**. Indices are 0-based.

## Hibiki panel (macOS, Windows)

Needs [ReaImGui](https://github.com/cfillion/reaimgui) ≥ 0.10 and an agent: Gamut or one of the CLI agents (see
[Connect an agent](#connect-an-agent-step-4)). The panel talks to the [agent gateway](#agent-gateway-codex-claude-code-kimi--in-the-same-panel)
on `127.0.0.1:47892`; for Gamut it uses the desktop app's local REST + SSE API (`127.0.0.1:47891`), the same one
Gamut's own UI uses.

The installer puts it in place. By hand: 1. Copy `panel/Hibiki.lua`, `panel/context.lua`, `panel/markdown.lua` and `panel/studio.lua` to `<REAPER resource path>/Scripts/Hibiki/`
(and `panel/Hibiki_Meter.jsfx` to `<REAPER resource path>/Effects/Hibiki/`), then **Actions → Load ReaScript** and run `Hibiki.lua`.
2. Optional: run `panel/restart_apply.sh` while REAPER is open and quit REAPER — it docks the panel on the right,
   binds **Cmd+L** to toggle it, and relaunches REAPER.

What it does: the header shows the agent and the model in effect (Gamut, Claude Code, Kimi, …); click it for
**Agent settings**, a Routing-style window with the provider, the Gamut agent, model / effort / mode, the context
switch and the live REAPER selections; the clock lists recent chats, `+` starts one. For Claude Code and Kimi,
**Open in …** reopens the chat in the agent's own CLI in Terminal. Replies stream with a markdown renderer; tool calls
collapse into one line per run. Every message carries a `[REAPER context]` block: project, tempo, cursor and nearby
markers, then each selection kind — time selection, razor areas, tracks, items, MIDI notes, envelope, FX — with how
long ago it was set and, for time/razor ranges, the chord markers and what plays there. Pills above the input show
the same selections, newest first. Enter sends, Shift+Enter is a newline. Drag to select message text and Cmd+C to
copy. Attach files with **+ File** or by dropping them on the panel: they're uploaded to the agent (Gamut's
`upload-file`; for ACP agents the gateway stores them and sends images as image blocks) and listed in the message as
`[Attached files:]` (for Gamut, whose copies live in the agent's container, followed by the files' paths on the
REAPER host, which `item import` needs). A Gamut agent's questions, secrets, script runs and approvals are answered in
the panel; connecting an account or MCP server, uploading a requested file, a browser step or computer use opens that
chat in Gamut (`superagent://agent/<slug>/sessions/<id>`). Scrolling follows Gamut's own follow engine. Chinese/Japanese IME:
ReaImGui passes keys to both the IME and ImGui, so the panel undoes ImGui's half of Backspace / arrows / Esc / Enter
while a composition is open and shows the pending pinyin under the input.

> Gamut's local API has no auth in desktop mode and listens on all interfaces. Block port 47891 in the macOS
> firewall if the Mac is on a network you don't trust.

### Around the chat (`panel/studio.lua`)

- **Version history.** After every agent reply that changed the project, a copy of it (saved or not;
  `Main_SaveProjectEx` to another path leaves the open project's path and dirty state alone) goes to
  `<project folder>/.hibiki/history/<name>/<stamp>.RPP.gz` with a line in `index.jsonl`: about 40 KB each, no media,
  the newest 200 kept. Each version is titled with the reply's own first sentence; hover lists what changed. The
  bridge knows what changed because it runs every request that can change the project in one undo block labelled
  `Hibiki <reply>: <what changed>` and lists the changes in ExtState `Hibiki/receipts`; for `run_lua` and raw API
  calls it diffs the project before and after (tracks, volume, pan, mute, FX added / removed / bypassed / offline,
  items, lanes, sends, tempo), and a first-line `-- comment` titles the script. Agent settings → Version history:
  **Current** (with **Save version** when it isn't in the history yet), then the 10 newest versions with the time to
  the second and **Go to**, which saves Current as a version first, then makes this tab that version.
- **Measure playback.** `Hibiki_Meter.jsfx` sits on the master's monitoring FX (never rendered) and writes a frame
  every 100 ms of playback to gmem `Hibiki`: LUFS-M/S (BS.1770 K-weighting), 4× oversampled true peak, sample peak,
  correlation, side vs mid and eight mid bands. The next message's context gets the last playback: bars, gated
  LUFS-I, the loudest LUFS-S and true peak with their bar.beat, correlation minimum, band levels and a per-bar
  LUFS-M / true-peak row. Switch it in Agent settings → Context → Measure playback.
- **Audition rack.** An agent offers audible alternatives (sounds, parts, effects; not levels) preferably as fixed
  lanes of one track tagged `P_EXT:hibiki_lanes = "<group>"` (one lane playing, lane names as labels), or by tagging tracks `P_EXT:hibiki_var = "<group>/<n>"` (one unmuted)
  or FX on one track with `P_EXT:hibiki_fxvar` lines `"<group>/<n>\t<fx GUID>"` (one enabled). The panel shows a row
  of numbered buttons per group above the input with the playing variant's name. Click or press 1–9 (panel focused)
  to switch (no undo point); when stopped, a click also loops the time selection, which the agent sets to the section
  where the variants differ, so a click is a listen. Hover = the loudness each variant measured while it played.
  **Keep n** deletes the other variants and their tags in one undo step.
- **Ears.** With a time selection or razor area, **Ears** renders it from the master (≤ 30 s, 24-bit WAV in the
  panel's private folder, your render settings restored afterwards), reads REAPER's LUFS-I / LUFS-S max / true peak,
  runs `hibiki ears` (stdlib spectrum: 1/3-octave mid and side, tilt, bands over/under the tilt, stereo, level over
  time → `.png` + `.md`) and attaches the picture, the summary and the audio to your next message.
- **Agent rules.** `/remember <rule>` saves a line to your `rules.md` (`/remember off: <id>` switches a
  convention off). Agent settings → Context → Agent rules shows `N defaults (M off) · K yours`; Edit opens
  `defaults.md` and `rules.md`.
  See [Rules for agents](#rules-for-agents).

## Rules for agents

Every agent gets one text: **Hibiki conventions** from your `defaults.md` followed by **your rules** from
`rules.md`, both in `~/.config/hibiki/brain/` (`HIBIKI_BRAIN` overrides the folder; the same path on Windows, under
your profile).

- `defaults.md` starts as a copy of the shipped `brain/defaults.md` (general know-how such as one DLSMusicDevice per
  project, never rendering onto an existing file), made by `hibiki setup` or the first read. It is yours: rewrite or
  delete any rule. Rules are bullets with a stable id, `- [single-dls] ...`.
- On every install or upgrade, `hibiki setup` merges the new shipped file in per id: a rule you left untouched gets
  the new text, one you edited keeps your wording, one you deleted stays deleted, a new id is added at the end;
  lines without an id are never touched (`brain/.defaults-state.json` remembers what was last shipped).
  `hibiki rules reset <id>` (or `--all`) brings the shipped text back.
- `rules.md` is free text, one rule per line (`/remember <rule>` in the panel adds one). It also understands
  `off: <id>` (leave a default out) and `[<id>] <text>` (replace its text), but editing `defaults.md` is simpler.
  `<!-- comments -->` are not sent.
- Delivered two ways: the MCP server appends the composed text to its `initialize` instructions (read at every
  session start, so edits apply to the next chat without a restart; Gamut agents and any MCP client see it), and the
  gateway writes it into `AGENTS.md`, `CLAUDE.md` and `GEMINI.md` in the ACP agents' working folder (a marked block;
  your own text in those files stays) before each new chat. Capped at 12,000 characters.
- `hibiki rules` prints what agents get, `hibiki rules --path` the rules.md path, `hibiki rules edit [defaults|mine]`
  opens both files (or one), `hibiki rules off <id>` / `on <id>` toggle a default from rules.md. The panel's
  Agent rules → Edit opens both files.

## Start with REAPER

The installer merges `reaper/__startup.lua` into `<REAPER resource path>/Scripts/__startup.lua` as a marked block. It starts the
MCP bridge and opens the chat panel on every launch, registering either script if REAPER doesn't know it yet.

## Agent gateway: Codex, Claude Code, Kimi, … in the same panel

`gateway/agent_gateway.py` is a small local server (`127.0.0.1:47892`, stdlib Python) that the panel talks to first.
It proxies Gamut agents unchanged and adds [ACP](https://agentclientprotocol.com) agents — Codex via
`@agentclientprotocol/codex-acp`, Claude Code via `@agentclientprotocol/claude-agent-acp`, Kimi Code CLI (`kimi acp`),
and anything else that speaks ACP — under the same API. Subscriptions work: Codex logs in with ChatGPT, Claude Code
reuses the local `claude` login, Kimi's login button opens `kimi login` (device code) in Terminal. An agent's
`loginVariants` turn its terminal login into one button per variant, each appending its `args` to the login
command (the Kimi entry ships kimi.ai = `--region global` and kimi.com = `--region mainland-cn`). Each ACP session gets this
repo's MCP server, so every backend can drive REAPER. The panel shows model / effort / mode pickers for both kinds
(Gamut's model catalog, ACP config options), permission buttons when an ACP agent asks before a tool call, and a
login button when the agent needs one. If the gateway isn't running the panel falls back to Gamut directly.
Every request except `/health` needs `Authorization: Bearer <token>` from `~/.config/agent-gateway/token` (created
with mode 0600 on first start; the panel reads it). Docker and Lima forward `host.docker.internal` /
`host.lima.internal` to the Mac's loopback, so without the token any container on the Mac could start a host agent.

```bash
hibiki agents add codex claude kimi   # Node (~/.local/node) + the ACP adapters, restarts the gateway
python3 gateway/test_gateway.py                   # fake Gamut + fake ACP agent, no network
```

Agents are listed in `~/.config/agent-gateway/config.json` (`acp: [{slug, name, command, env, cwd}]`,
`mcpServers: [...]`). Transcripts of ACP sessions are kept in `~/.config/agent-gateway/sessions/`.
`hibiki agents add` installs each adapter at a pinned npm version with install scripts off (MiniMax keeps them: its
SQLite binding and ripgrep are fetched by them).

An ACP agent starts on first use (a message, its config, or `/status?probe=<slug>`; `probe=1` only checks that the
binary is there and returns the last-known login state). After 10 minutes with no running turn and no open stream
(`AGENT_GATEWAY_IDLE`, seconds) the gateway stops it and the MCP servers it started; the next message restarts it and
reloads the chat.

Gamut desktop on the same Mac: `install.sh` registers the MCP as `http://localhost:8787/mcp` (no tunnel). Agent running somewhere
else and need to reach REAPER over the internet? See [docs/remote-host.md](docs/remote-host.md).

## Troubleshooting

`hibiki recover` (also the **Recover** button in the panel's settings) restarts the MCP front and the gateway (their
ACP agents go with it), kills leftover panel stream `curl`s, puts back a missing bridge script / panel / token, waits
up to 10 s for both services and reports the bridge heartbeat. It never touches REAPER: a stale heartbeat means
REAPER is busy or hung, and the watchdog restarts a hung one. `--json` prints `{"ok", "steps": [{"name", "ok",
"detail"}]}`; exit 0 when the MCP and the gateway answer. `hibiki doctor` lists everything else.

## Security notes

- The HTTP front (`127.0.0.1:8787`) refuses to start with a bearer shorter than 32 characters; `hibiki setup` and
  `scripts/macos-host-bootstrap.sh` generate one with a CSPRNG when none is given.
- Exposed through a Cloudflare tunnel, the bearer is the only gate in front of `run_lua`, i.e. a shell on the Mac. Only
  run the tunnel while an agent outside the Mac needs it, and put a Cloudflare Access policy (service token or
  identity) in front of the tunnel hostname so requests are filtered before they reach the Mac.

## Tools

`status` `transport` `track` `midi` `fx` `send` `item` `envelope` `project` `render` `action` `reaper_call` `run_lua` `batch`

Behaviour worth knowing (all optional parameters; older calls work unchanged):

- `status` also returns `any_solo` (REAPER's own solo state, which can differ from a track's `I_SOLO`), `master_mute` and `dirty`.
- `render` runs action 40101 (set all media online) first (`media_online=false` skips it), refuses when a target file already exists (REAPER's overwrite prompt would block the bridge) and when tracks are soloed (`allow_solo=true`, or `solo_indices` / `mute_indices` to solo/mute tracks for this render only; they are restored afterwards). It returns `files: [{path, bytes, length_sec, peak_db, lufs_i}]` and `warnings` (near-silent, file not written, master muted, stems that came out as the master). `measure=false` skips the loudness scan.
- `fx set` takes `formatted` instead of `value`: the value as the plugin shows it (`-18` for dB, `4` for 4:1, `inf`, or a label such as `3.2k`). It searches the display text and returns the `formatted` value it actually set.
- `send add|update` take `mode` (`post_fader` / `pre_fader` / `pre_fx`) and `src_channel` / `dst_channel`, the first channel of a stereo pair counted from 0 (`dst_channel=2` = channels 3/4, a compressor's sidechain input). The destination track gets more channels if it needs them.
- `envelope get|set` take `unit=db` for volume-type envelopes. `set` turns an inactive (`ACT 0`) envelope back on and rejects points that have no `value`.
- `run_lua` takes `timeout` (seconds, default 10, at most 600). Errors quote the failing source line. REAPER is frozen while a snippet runs, so start long host commands in the background and poll their log.
- Every call that can change the project is one undo point labelled `Hibiki <reply>: <what changed>` (a `batch` is one point for all its calls, with no rollback: `stop_on_error=true` skips the rest after a failure); see [Version history](#around-the-chat-panelstudiolua).
- A reply works on the project tab that was in front when it first changed something: if another tab comes to the front, writes and renders are refused (from the panel, until the reply ends; without the panel the first refusal re-pins to the new tab).
- `status` always returns `cursor_beats`, `time_selection`, selected tracks (`selected`) and `selected_items`; `detail=true` adds `tempo_map` (tempo and meter changes).
- `item` arranges: `split` (`at_beats`), `delete`, `duplicate` (an unpooled copy), and `update` with `left_edge_beats` (trim the start, content stays put), `dest_track_index`, `active_take`, `fade_in_sec` / `fade_out_sec` and `fade_*_shape`. Item indices follow position, so list again after a move.
- `envelope get|set` take `start_beats` / `end_beats`: `set` then replaces only the points in that range.
- `transport goto` moves the edit cursor to `position_beats` or a marker/region (number or name); transport returns `position_sec` and `position_beats`.
- `render` takes `format` (`wav` with `bit_depth` 16 / 24 / 32 float, or `mp3` at 320 kbps) for that render only. `fx params` takes `filter`; `midi get_cc` reads CC, program and pitch bend.
- `run_lua`'s `timeout` stops a snippet that is still running Lua (what it did until then stays done); a call blocked inside REAPER (ExecProcess, a render, a dialog) can't be stopped.
- One REAPER serves the mailbox: a second REAPER's bridge waits until the first one's heartbeat goes stale, and a request is claimed by renaming it, so it never runs twice.

## Tests

```
python3 tests/test_server.py                         # MCP server + fake bridge, versions in step
uv run --with lupa python tests/test_bridge_lua.py   # bridge.lua against a fake ReaScript API
uv run --with lupa python panel/test_panel.py   # chat panel events, sends and cards, fake reaper/ImGui
python3 gateway/test_gateway.py                      # agent gateway against fake Gamut + fake ACP agent
python3 tests/test_suite.py                          # setup / doctor / connect / uninstall on a fake HOME
python3 tests/test_ears.py                           # `hibiki ears` on synthetic WAVs
uv run --with lupa python scripts/check_syntax.py    # every .lua compiles under Lua 5.4, every .sh parses
```

CI runs all of these on every push: the Python suites on 3.9 (the macOS host's `/usr/bin/python3`) and 3.12.

None of these need REAPER. The Lua-based ones need `lupa` (CI installs it).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately: [SECURITY.md](SECURITY.md).

## License

MIT
