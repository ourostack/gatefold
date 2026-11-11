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
# Limits, in whole seconds; the offline test (scripts/test-ci-simulator.sh) shortens them. An override that is empty
# means the default; a fraction is rounded down; anything else is refused.
limit() {
  local v="${1:-$2}"; v="${v%%.*}"
  [[ $v =~ ^[0-9]+$ ]] || { echo "boot-sim.sh: a limit must be a number of seconds, not '$1'" >&2; exit 2; }
  echo "$v"
}
BOOTSTATUS_LIMIT="$(limit "${BOOT_SIM_BOOTSTATUS_LIMIT:-}" 420)" || exit 2
RECHECK_LIMIT="$(limit "${BOOT_SIM_RECHECK_LIMIT:-}" 90)" || exit 2
LIST_LIMIT="$(limit "${BOOT_SIM_LIST_LIMIT:-}" 60)" || exit 2
# bootstatus is asked in slices of this many seconds, within BOOTSTATUS_LIMIT in all: one call can miss the end of the
# boot and wait out its whole limit while the device is ready (gatefold#227: 7 of 41 boots over 300 s on 2026-11-11 hung 420 s, and
# a second bootstatus then finished at once), so a missed end now costs one slice, not 420 s.
SLICE_LIMIT="$(limit "${BOOT_SIM_BOOTSTATUS_SLICE:-}" 60)" || exit 2
# A device still not listed Booted this long after its boot was asked for is given up on then, not at BOOTSTATUS_LIMIT.
NOBOOT_LIMIT="$(limit "${BOOT_SIM_NOBOOT_LIMIT:-}" 180)" || exit 2
# After a clean bootstatus the listing only confirms (a listing that doesn't answer leaves it standing), so it gets a
# short bound: 14 of those 41 boots spent 60 s on one that didn't answer.
CONFIRM_LIMIT="$(limit "${BOOT_SIM_CONFIRM_LIMIT:-}" 15)" || exit 2
# within <seconds> <command...>: the command's own exit code, or 124 if it ran out of time; then it is killed (TERM,
# then KILL 5 s later) and this logs "hung". (A command that exits 124 by itself reads as a hang too; simctl does
# not.) The limit is measured on the clock ($SECONDS), not by counting polls, which run slow on a busy runner.
# This shell watches the command itself, every 0.2 s, so no watchdog
# process exists to race or outlive it: a watchdog subshell could be stopped between forking its sleep and noting its
# PID, and the orphaned sleep then held `$(... 2>&1)` open for the whole limit (#74 review). The command writes to
# files, not to the caller's pipe, and they are copied out when it ends or is killed: a child of the command that
# outlives the kill would otherwise hold that pipe open, and the caller's `$(...)` waited on it (gatefold#227: 60 s
# slices took 79 and 96 s, and a listing bounded at 60 s held the boot about 140 s more, in probe 43007631651). No
# pkill, so it runs the same on macOS's /bin/bash 3.2 and in the core job's swift:6.2 container.
WITHIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/boot-sim.XXXXXX")" || exit 2
trap 'rm -rf "$WITHIN_DIR"' EXIT
trap 'exit 143' TERM
within() {
  local secs="$1"; shift
  # Fresh files per call (mktemp, not a counter: most calls run in a `$(...)` subshell, where a counter never moves),
  # so a child an earlier, killed call left behind can't write into this call's output.
  local out err code
  out="$(mktemp "$WITHIN_DIR/out.XXXXXX")" && err="$(mktemp "$WITHIN_DIR/err.XXXXXX")" || return 125
  "$@" >"$out" 2>"$err" </dev/null &
  local pid=$! end=$(( SECONDS + secs ))
  _within_wait "$pid" "$end" "$secs" "$@"; code=$?
  cat "$err" >&2; cat "$out"
  return $code
}
_within_wait() {
  local pid="$1" end="$2" secs="$3"; shift 3
  while kill -0 "$pid" 2>/dev/null; do
    # Past the end, not at it: $SECONDS counts whole seconds, so this fires between secs and secs + 1, never early.
    if (( SECONDS > end )); then
      echo "$* hung past $secs s" >&2
      kill "$pid" 2>/dev/null
      local grace=$(( SECONDS + 5 ))
      while kill -0 "$pid" 2>/dev/null && (( SECONDS < grace )); do sleep 0.2; done
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
  within "${2:-$LIST_LIMIT}" xcrun simctl list devices -j | python3 -c '
import json, sys
try: print(any(d["udid"] == sys.argv[1] and d["state"] == "Booted" for v in json.load(sys.stdin)["devices"].values() for d in v))
except ValueError: print("Unknown")' "$1"
}
# The device's listed state ("Booted", "Booting", "Shutdown", ...), "Missing" when it isn't listed, or "Unknown" when
# the listing did not answer in time.
device_state() {
  within "$LIST_LIMIT" xcrun simctl list devices -j | python3 -c '
import json, sys
try: print(next((d["state"] for v in json.load(sys.stdin)["devices"].values() for d in v if d["udid"] == sys.argv[1]), "Missing"))
except ValueError: print("Unknown")' "$1"
}
try_boot() {
  xcrun simctl boot "$1" >&2 || true
  # Every slice's output is kept: a "Failed" printed in a slice that was then cut off still fails the boot (#57).
  local began=$SECONDS code=124 rest slice asked="" all="" boot=-b
  while :; do
    rest=$(( BOOTSTATUS_LIMIT - (SECONDS - began) ))
    (( rest < 1 )) && break
    slice=$(( rest < SLICE_LIMIT ? rest : SLICE_LIMIT ))
    # -b only on the first ask: later slices only wait, so they can't boot a device again whose first boot failed.
    status="$(within "$slice" xcrun simctl bootstatus "$1" $boot 2>&1)"; code=$?; boot=""
    all="$all$status"$'\n'
    [[ $code == 124 ]] || break
    # Once, past NOBOOT_LIMIT and with time for the listing (its limit, its kill grace and a second of $SECONDS
    # rounding) inside the limit: a device listed Shutdown, or not listed, never came up and goes now. One still
    # Booting is slow, not dead (boots have taken 10 min, gatefold#198), so it keeps its whole limit.
    if [[ -z $asked ]] && (( SECONDS - began >= NOBOOT_LIMIT && SECONDS - began + LIST_LIMIT + 6 < BOOTSTATUS_LIMIT )); then
      asked=1
      local now; now="$(device_state "$1")"
      if [[ $now == Shutdown || $now == Missing ]]; then
        echo "$1 never booted: listed $now $(( SECONDS - began )) s after its boot was asked for" >&2
        within "$LIST_LIMIT" xcrun simctl shutdown "$1" >/dev/null 2>&1
        return 1
      fi
    fi
    echo "$1: bootstatus gave no answer in a ${slice} s slice, $(( SECONDS - began )) s in; asking again" >&2
  done
  status="$all"
  [[ $code == 124 ]] || echo "$1: bootstatus finished after $(( SECONDS - began )) s" >&2
  if [[ $code == 124 ]]; then
    echo "$status" | tail -3 >&2
    # Listed Booted is not ready: the data migration runs after that, and bootstatus is what waits for it (#57). So a
    # device that is up gets one more bounded bootstatus; it passes only if that one finishes clean (gatefold#132:
    # the old watchdog shut down a device that had booted, and the attempt failed with it).
    local state; state="$(booted "$1")"
    [[ $state == Unknown ]] && state="$(booted "$1")"
    if [[ $state == True ]]; then
      status="$(within "$RECHECK_LIMIT" xcrun simctl bootstatus "$1" -b 2>&1)"
      # A Failed from any slice still counts (#57), not only the recheck's own.
      if [[ $? != 124 ]] && ! grep -q "Failed" <<<"$status$all"; then
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
  # A bootstatus that exited 0 is the stronger word: a listing that did not answer does not undo it (as
  # ci-simulator.py since 8b144cf; a healthy device was thrown away over one, run 42502520118). One that exited
  # otherwise is not trusted on an unanswered listing (both happen when CoreSimulatorService is failing). The listing
  # only confirms here, so its bound is short; ci-simulator.py's check still confirms Booted and the runtime before the
  # device is used.
  case "$(booted "$1" "$CONFIRM_LIMIT")" in
    True) return 0 ;;
    Unknown)
      if [[ $code == 0 ]]; then
        echo "$1: bootstatus finished clean; the device listing did not answer, so that stands" >&2; return 0
      fi
      echo "$1: bootstatus exited $code and the device listing did not answer; taken as not booted" >&2; return 1 ;;
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
