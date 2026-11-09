#!/usr/bin/env bash
# Create and boot a simulator, and print its UDID once it is really booted.
# `simctl bootstatus -b` can exit 0 on a device whose first boot failed ("Data Migration Failed",
# or a runtime that won't mount), and the install then dies minutes later (#57). So check the
# device's state. On some hosts the failure repeats on every new device even after restarting
# CoreSimulatorService (#57, runs 42437958662 and 42439381768), so the attempts escalate:
#   1. a plain create and boot;
#   2. the same device booted a second time (the migration has run once), then a fresh one;
#   3. `xcodebuild -runFirstLaunch` and a service restart, then a fresh device.
# On every failure the device's migration lines go to the log, so the next failure names its cause.
# Usage: boot-sim.sh <name> <device type id> <runtime id>
set -uo pipefail
name="$1" type="$2" runtime="$3"
booted() { xcrun simctl list devices -j | python3 -c 'import json,sys; print(any(d["udid"]==sys.argv[1] and d["state"]=="Booted" for v in json.load(sys.stdin)["devices"].values() for d in v))' "$1"; }
try_boot() {
  xcrun simctl boot "$1" >&2 || true
  # A bootstatus that hangs is ended after 7 min, so the next attempt still runs. The device is shut down only if it
  # never booted: on gatefold#132 (job 128961815446) bootstatus hung on a device that was up, the shutdown then took it
  # down, and the attempt was called failed with the device it had just booted.
  local out; out="$(mktemp)"
  xcrun simctl bootstatus "$1" -b >"$out" 2>&1 &
  local waiter=$!
  ( sleep 420; echo "bootstatus for $1 hung past 7 min" >&2
    [[ "$(booted "$1")" == "True" ]] || xcrun simctl shutdown "$1" >/dev/null 2>&1
    kill "$waiter" 2>/dev/null ) >/dev/null &
  local watchdog=$!
  wait "$waiter" 2>/dev/null || true
  # The subshell's sleep too, so nothing outlives this script holding its stderr open.
  pkill -P "$watchdog" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  status="$(cat "$out")"
  echo "$status" | tail -3 >&2
  # The device's own state decides, read after the watchdog has finished, not the bootstatus exit.
  [[ "$(booted "$1")" == "True" ]] && ! grep -q "Failed" <<<"$status"
}
diagnose() {
  echo "--- migration lines for $1" >&2
  grep -hiE "migrat|datamigrator|failed" "$HOME/Library/Logs/CoreSimulator/$1/system.log" 2>/dev/null | tail -15 >&2 || true
  df -h / | tail -1 >&2
}
restart_service() {
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  killall -9 com.apple.CoreSimulator.CoreSimulatorService >/dev/null 2>&1 || true
  sleep 20
  xcrun simctl list devices >/dev/null 2>&1 || true
}
for attempt in 1 2 3; do
  if [[ $attempt == 3 ]]; then
    xcodebuild -runFirstLaunch >&2 || true
    restart_service
  fi
  udid="$(xcrun simctl create "$name" "$type" "$runtime")" || { echo "attempt $attempt: create failed" >&2; restart_service; continue; }
  if try_boot "$udid"; then echo "$udid"; exit 0; fi
  diagnose "$udid"
  if [[ $attempt == 2 ]]; then
    echo "attempt 2: booting $udid a second time" >&2
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    if try_boot "$udid"; then echo "$udid"; exit 0; fi
  fi
  echo "attempt $attempt: $udid did not boot" >&2
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >&2 || true
  restart_service
done
echo "the $name simulator never booted" >&2
exit 1
