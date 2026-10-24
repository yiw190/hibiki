#!/bin/bash
# Keep REAPER and its MCP bridge up on this Mac. launchd runs it every 30 s (`hibiki watchdog on`).
#   - REAPER gone after a crash (fresh .ips report) or not started since boot/login -> open it.
#     A plain user quit is respected.
#   - REAPER running but the bridge heartbeat is stale for STALE_KILL s while nobody has touched the
#     Mac for IDLE_KILL s -> kill and relaunch (__startup.lua brings the bridge back).
# Pause: touch ~/.config/reaper-mcp/watchdog.off   Log: ~/Library/Logs/reaper-watchdog.log
# WATCHDOG_DRY_RUN=1 logs decisions without acting.
set -u
CFG="$HOME/.config/reaper-mcp"
ST="$HOME/Library/Application Support/reaper-mcp/watchdog"
IPC="${REAPER_MCP_IPC_DIR:-$HOME/Library/Application Support/reaper-mcp/ipc}"
LOG="${WATCHDOG_LOG:-$HOME/Library/Logs/reaper-watchdog.log}"
PROC="${WATCHDOG_PROC:-^/.*/REAPER\.app/Contents/MacOS/REAPER( |$)}"
STALE_KILL="${WATCHDOG_STALE_KILL:-600}"
IDLE_KILL="${WATCHDOG_IDLE_KILL:-600}"
BUSY_KILL=1800
STARTUP_GRACE=180
MAX_LAUNCHES=3
DRY="${WATCHDOG_DRY_RUN:-0}"

mkdir -p "$ST"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
[ -f "$CFG/watchdog.off" ] && exit 0

now=$(date +%s)
mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
# -a: without it pgrep hides its own ancestors (e.g. when run from REAPER's io.popen)
running() { pgrep -a -f "$PROC" >/dev/null; }

launch() {
  local recent
  recent=$(awk -v t=$((now - 1800)) '$1 > t' "$ST/launches" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$recent" -ge "$MAX_LAUNCHES" ]; then
    [ -f "$ST/gave_up" ] || { log "GIVE UP: $recent launches in 30 min ($1)"; touch "$ST/gave_up"; }
    return
  fi
  log "launch REAPER ($1)"
  [ "$DRY" = 1 ] && return
  rm -f "$ST/gave_up"
  echo "$now" >> "$ST/launches"
  echo "$now" > "$ST/launched_at"
  touch "$ST/seen"
  open -a REAPER
}

if ! running; then
  seen=$(mtime "$ST/seen")
  boot=$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/')
  crash=$(ls -t "$HOME/Library/Logs/DiagnosticReports"/REAPER*.ips 2>/dev/null | head -1)
  if [ -f "$ST/relaunch" ]; then
    [ "$DRY" = 1 ] || rm -f "$ST/relaunch"
    launch "after watchdog restart"
  elif [ "$seen" -lt "$boot" ]; then
    launch "not started since boot"
  elif [ -n "$crash" ] && [ "$(mtime "$crash")" -ge $((seen - 60)) ]; then
    launch "crash: $(basename "$crash")"
  fi
  exit 0
fi

[ "$DRY" = 1 ] || touch "$ST/seen"
[ $((now - $(cat "$ST/launched_at" 2>/dev/null || echo 0))) -lt "$STARTUP_GRACE" ] && exit 0

age=$((now - $(mtime "$IPC/heartbeat")))
limit=$STALE_KILL
[ -f "$IPC/busy" ] && limit=$BUSY_KILL
if [ "$age" -lt "$limit" ]; then
  rm -f "$ST/stale_logged"
  exit 0
fi
[ -f "$ST/stale_logged" ] || { log "bridge heartbeat stale ${age}s"; touch "$ST/stale_logged"; }

idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
[ "${idle:-0}" -lt "$IDLE_KILL" ] && exit 0

log "restart hung REAPER (heartbeat ${age}s, user idle ${idle}s)"
[ "$DRY" = 1 ] && exit 0
touch "$ST/relaunch"
pkill -TERM -f "$PROC"
for _ in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 1; done
running && pkill -9 -f "$PROC"
sleep 2
rm -f "$ST/relaunch" "$ST/stale_logged"
launch "after hang"
