#!/usr/bin/env bash
# Create and boot a simulator, and print its UDID once it is really booted.
# `simctl bootstatus -b` can exit 0 on a device whose first boot failed ("Data Migration Failed",
# or a runtime that won't mount), and the install then dies minutes later (#57). So check the
# device's state, and try a fresh device up to three times. A failed first boot can repeat on every
# new device on the same host, so each retry also restarts CoreSimulatorService (#57, run 42437958662).
# Usage: boot-sim.sh <name> <device type id> <runtime id>
set -uo pipefail
name="$1" type="$2" runtime="$3"
booted() { xcrun simctl list devices -j | python3 -c 'import json,sys; print(any(d["udid"]==sys.argv[1] and d["state"]=="Booted" for v in json.load(sys.stdin)["devices"].values() for d in v))' "$1"; }
for attempt in 1 2 3; do
  udid="$(xcrun simctl create "$name" "$type" "$runtime")" || { echo "attempt $attempt: create failed" >&2; sleep 20; continue; }
  xcrun simctl boot "$udid" >&2 || true
  status="$(xcrun simctl bootstatus "$udid" -b 2>&1)" || true
  echo "$status" | tail -3 >&2
  if [[ "$(booted "$udid")" == "True" ]] && ! grep -q "Failed" <<<"$status"; then
    echo "$udid"
    exit 0
  fi
  echo "attempt $attempt: $udid did not boot" >&2
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >&2 || true
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  killall -9 com.apple.CoreSimulator.CoreSimulatorService >/dev/null 2>&1 || true
  sleep 20
done
echo "the $name simulator never booted" >&2
exit 1
