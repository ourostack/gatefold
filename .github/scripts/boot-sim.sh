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
# Limits, in seconds; the offline test (scripts/test-ci-simulator.sh) shortens them.
BOOTSTATUS_LIMIT="${BOOT_SIM_BOOTSTATUS_LIMIT:-420}" RECHECK_LIMIT="${BOOT_SIM_RECHECK_LIMIT:-90}" LIST_LIMIT="${BOOT_SIM_LIST_LIMIT:-60}"
# within <seconds> <command...>: the command's own exit code, or 124 if it ran out of time; then it is killed (TERM,
# then KILL 5 s later) and this logs "hung". This shell watches the command itself, every 0.2 s, so no watchdog
# process exists to race or outlive it: a watchdog subshell could be stopped between forking its sleep and noting its
# PID, and the orphaned sleep then held `$(... 2>&1)` open for the whole limit (#74 review). No pkill or temp files,
# so it runs the same on macOS's /bin/bash 3.2 and in the core job's swift:6.2 container.
within() {
  local secs="$1"; shift
  "$@" &
  local pid=$! ticks=$(( secs * 5 ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( ticks-- <= 0 )); then
      echo "$* hung past $secs s" >&2
      kill "$pid" 2>/dev/null
      local grace=25
      while kill -0 "$pid" 2>/dev/null && (( grace-- > 0 )); do sleep 0.2; done
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}
# "True", "False", or "Unknown" when the listing did not answer in time (run 42502520118).
booted() {
  within "$LIST_LIMIT" xcrun simctl list devices -j | python3 -c '
import json, sys
try: print(any(d["udid"] == sys.argv[1] and d["state"] == "Booted" for v in json.load(sys.stdin)["devices"].values() for d in v))
except ValueError: print("Unknown")' "$1"
}
try_boot() {
  xcrun simctl boot "$1" >&2 || true
  status="$(within "$BOOTSTATUS_LIMIT" xcrun simctl bootstatus "$1" -b 2>&1)"
  if [[ $? == 124 ]]; then
    echo "$status" | tail -3 >&2
    # Listed Booted is not ready: the data migration runs after that, and bootstatus is what waits for it (#57). So a
    # device that is up gets one more bounded bootstatus; it passes only if that one finishes clean (gatefold#132:
    # the old watchdog shut down a device that had booted, and the attempt failed with it).
    local state; state="$(booted "$1")"
    [[ $state == Unknown ]] && state="$(booted "$1")"
    if [[ $state == True ]]; then
      status="$(within "$RECHECK_LIMIT" xcrun simctl bootstatus "$1" -b 2>&1)"
      if [[ $? != 124 ]] && ! grep -q "Failed" <<<"$status"; then
        echo "$status" | tail -3 >&2
        echo "$1 is booted; its second bootstatus finished" >&2
        return 0
      fi
      echo "$1 is listed Booted, but its second bootstatus did not finish clean" >&2
    elif [[ $state == Unknown ]]; then
      echo "$1: state unknown (the device listing did not answer twice); taken as not booted" >&2
    else
      echo "$1 never booted" >&2
    fi
    within "$LIST_LIMIT" xcrun simctl shutdown "$1" >/dev/null 2>&1
    return 1
  fi
  echo "$status" | tail -3 >&2
  grep -q "Failed" <<<"$status" && return 1
  # bootstatus finished clean, which is the stronger word: a listing that did not answer does not undo it (as
  # ci-simulator.py since 8b144cf; a healthy device was thrown away over one, run 42502520118).
  case "$(booted "$1")" in
    True) return 0 ;;
    Unknown) echo "$1: bootstatus finished clean; the device listing did not answer, so that stands" >&2; return 0 ;;
    *) return 1 ;;
  esac
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
