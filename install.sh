#!/bin/sh
# Install or upgrade the suite for this macOS user from this clone (the .pkg runs the same `setup`).
# The LaunchAgents run from the clone, so keep it. WITH_AGENTS=1 also installs Codex, Claude Code and Kimi.
set -eu
cd "$(dirname "$0")"
/usr/bin/python3 -m reaper_mcp setup "$@"
if [ "${WITH_AGENTS:-0}" = 1 ]; then
  /usr/bin/python3 -m reaper_mcp agents add codex claude kimi
fi
