#!/bin/bash
# Remote host: make REAPER on this Mac reachable from an agent elsewhere through a Cloudflare named tunnel.
# Installs the suite from a clone (~/reaper-mcp) with the given bearer, then cloudflared as a LaunchAgent.
# Needs CLOUDFLARE_TUNNEL_TOKEN (env or ~/.config/reaper-mcp/env). REAPER_MCP_BEARER (>= 32 characters) is kept if
# given, otherwise generated. See docs/remote-host.md.
set -euo pipefail
mkdir -p "$HOME/Library/Logs"
exec > >(tee -a "$HOME/Library/Logs/reaper-mcp-bootstrap.log") 2>&1
echo "=== reaper-mcp bootstrap $(date) ==="
echo "host=$(hostname) arch=$(uname -m) user=$(whoami)"

BIN="$HOME/.local/bin"
CFG="$HOME/.config/reaper-mcp"
LAUNCH="$HOME/Library/LaunchAgents"
REPO="${REAPER_MCP_REPO:-$HOME/reaper-mcp}"
LABEL=com.hibiki.cloudflared
mkdir -p "$BIN" "$CFG" "$LAUNCH"
export PATH="$BIN:$PATH"

if [ -f "$CFG/env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CFG/env"
  set +a
fi
if [ -z "${REAPER_MCP_BEARER:-}" ]; then
  REAPER_MCP_BEARER=$(/usr/bin/python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  echo "generated a new REAPER_MCP_BEARER (saved to $CFG/token)"
fi
if [ "${#REAPER_MCP_BEARER}" -lt 32 ]; then
  echo "REAPER_MCP_BEARER must be at least 32 characters; unset it to have one generated" >&2
  exit 1
fi
: "${CLOUDFLARE_TUNNEL_TOKEN:?set CLOUDFLARE_TUNNEL_TOKEN}"
REAPER_MCP_PORT="${REAPER_MCP_PORT:-8787}"

CLOUDFLARED_VERSION=2026.10.3
if [ ! -x "$BIN/cloudflared" ]; then
  echo "installing cloudflared $CLOUDFLARED_VERSION"
  tmp=$(mktemp -d)
  if [ "$(uname -m)" = arm64 ]; then
    ARCH=arm64; SHA=1165d14b6f6360a3b8c283d7d1100024d6ec7cd9bc9e32519e96150645f3ec55
  else
    ARCH=amd64; SHA=81b7b85f2376815c4f59b1aa323887b62e16ce8b67555c2e1577dc23f2a82000
  fi
  curl -fL "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-darwin-$ARCH.tgz" -o "$tmp/cf.tgz"
  if [ "$(shasum -a 256 "$tmp/cf.tgz" | awk '{print $1}')" != "$SHA" ]; then
    echo "cloudflared download failed its sha256 check" >&2
    rm -rf "$tmp"
    exit 1
  fi
  tar -xzf "$tmp/cf.tgz" -C "$tmp"
  cp "$(find "$tmp" -type f -name 'cloudflared*' | head -1)" "$BIN/cloudflared"
  chmod +x "$BIN/cloudflared"
  rm -rf "$tmp"
fi
"$BIN/cloudflared" --version

if [ ! -d "$REPO/.git" ]; then
  git clone https://github.com/yiw190/hibiki.git "$REPO"
else
  git -C "$REPO" pull --ff-only || echo "WARNING: could not fast-forward $REPO; running the checked-out version" >&2
fi

umask 077
cat > "$CFG/env" << ENVEOF
REAPER_MCP_BEARER=$REAPER_MCP_BEARER
REAPER_MCP_PORT=$REAPER_MCP_PORT
CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN
ENVEOF
printf '%s\n' "$REAPER_MCP_BEARER" > "$CFG/token"
umask 022

cd "$REPO"
REAPER_MCP_PORT="$REAPER_MCP_PORT" /usr/bin/python3 -m reaper_mcp setup
/usr/bin/python3 -m reaper_mcp watchdog on

uid=$(id -u)
for old in com.yitian.cloudflared-reaper "$LABEL"; do
  launchctl bootout "gui/$uid/$old" 2> /dev/null || true
  rm -f "$LAUNCH/$old.plist"
done
# the tunnel token goes in the environment, not argv: argv is visible to every user via ps
export CLOUDFLARE_TUNNEL_TOKEN
LABEL="$LABEL" BIN="$BIN" /usr/bin/python3 -c '
import os, plistlib
from pathlib import Path
label = os.environ["LABEL"]
log = str(Path.home() / "Library/Logs/cloudflared.log")
path = Path.home() / "Library/LaunchAgents" / (label + ".plist")
fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "wb") as f:
    plistlib.dump({"Label": label, "ProgramArguments": [os.environ["BIN"] + "/cloudflared", "tunnel", "run"],
                   "EnvironmentVariables": {"TUNNEL_TOKEN": os.environ["CLOUDFLARE_TUNNEL_TOKEN"]},
                   "RunAtLoad": True, "KeepAlive": True, "StandardOutPath": log, "StandardErrorPath": log}, f)
'
launchctl bootstrap "gui/$uid" "$LAUNCH/$LABEL.plist"
echo "=== bootstrap done $(date) ==="
