#!/usr/bin/env bash
# Probe for gatefold#198 (never merged). Usage: sim.sh pick | sample <label> <seconds> | settle <seconds>
set -uo pipefail
cmd="$1"; shift
case "$cmd" in
pick)
  # The newest iOS runtime at or below the SDK that offers an iPad Pro 13-inch: prints "<runtime id> <device type id>".
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
sdk = tuple(int(x) for x in sys.argv[1].split(".")[:2])
best = None
for r in json.load(sys.stdin)["runtimes"]:
    if r.get("platform") != "iOS" or not r.get("isAvailable"): continue
    v = tuple(int(x) for x in r["version"].split(".")[:2])
    if v > sdk: continue
    for t in r.get("supportedDeviceTypes", []):
        if t["name"].startswith("iPad Pro 13-inch"):
            if best is None or v > best[0]: best = (v, r["identifier"], t["identifier"])
            break
print(best[1], best[2])' "$sdk" ;;
sample)
  # Every 20 s for <seconds>: the 1-min load and the top three processes.
  label="$1" secs="$2" end=$(( SECONDS + secs ))
  while (( SECONDS < end )); do
    echo "LOAD $label t=$SECONDS $(date -u +%T) $(sysctl -n vm.loadavg | awk '{print $2}') | $(ps -Aceo pcpu=,comm= -r | head -3 | tr -s ' ' | tr '\n' ';')"
    sleep 20
  done ;;
settle)
  # Wait until the 1-min load stays under 15 for a minute, or <seconds> pass; prints how long it took.
  secs="$1" end=$(( SECONDS + secs )) calm=0 start=$SECONDS
  while (( SECONDS < end )); do
    l=$(sysctl -n vm.loadavg | awk '{print int($2)}')
    if (( l < 15 )); then calm=$((calm+1)); else calm=0; fi
    (( calm >= 3 )) && { echo "SETTLED after $(( SECONDS - start )) s"; exit 0; }
    sleep 20
  done
  echo "NOT SETTLED after $secs s" ;;
esac
