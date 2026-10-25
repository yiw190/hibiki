# Remote host (macOS + Cloudflare Tunnel)

Only needed when the agent runs somewhere else (e.g. a cloud container) and has to reach REAPER on a Mac over the
internet. The tunnel puts `run_lua` (Lua inside REAPER, and through it a shell on the Mac) on the internet behind
one bearer: run it only while such an agent needs it, and put a Cloudflare Access policy in front of the hostname. Local MCP clients and the agent gateway talk to REAPER directly over stdio and don't need any of this.

**Gamut desktop on the same Mac doesn't need it either.** `hibiki setup` (the .pkg or `install.sh`) runs
`reaper_mcp/http_server.py` (bearer auth) and registers the MCP in Gamut as `http://localhost:8787/mcp`: Gamut desktop
makes the connection itself and allows loopback MCP URLs, so it works whether its agent containers run in Lima, Docker
or anything else.

`scripts/macos-host-bootstrap.sh` clones this repo to `~/reaper-mcp`, runs `setup` from it with your bearer
(`REAPER_MCP_BEARER`, at least 32 characters, becomes `~/.config/reaper-mcp/token`; left unset, one is generated), turns the watchdog on and adds cloudflared (a pinned release, sha256-checked) as the LaunchAgent
`com.hibiki.cloudflared` (tunnel token in its environment, not on the command line). Secrets come from
`~/.config/reaper-mcp/env` and never touch the repo.

`scripts/deploy_bridge.py stage | swap | restart | verify` pushes a new bridge into a running REAPER without restarting
it, and restarts the HTTP front so it loads a new `server.py`. It targets a clone at `~/reaper-mcp`.
