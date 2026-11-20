#!/usr/bin/env bash
# PROBE ONLY (ci-cached-sim): does a simulator that has booted once, saved and restored, boot in seconds on the runner?
#   sim-cache-probe.sh plan <device prefix>      -> KIND, RUNTIME, RUNTIME_BUILD, XCODE_BUILD, SIMKEY to $GITHUB_ENV
#   sim-cache-probe.sh seed                     first boot (boot-sim.sh, as today), shutdown, copy into $SET
#   sim-cache-probe.sh clone                    the restored device cloned into the default set, then booted
#   sim-cache-probe.sh restart                  the other path: restored dir moved into Devices, service restarted
set -uo pipefail
SET="$HOME/simcache/set"
say() { echo "$*"; [[ -n ${GITHUB_STEP_SUMMARY:-} ]] && echo "- $*" >> "$GITHUB_STEP_SUMMARY"; }
load() { sysctl -n vm.loadavg; }
case "$1" in
plan)
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
  xcrun simctl list runtimes -j > "$RUNNER_TEMP/runtimes.json"
  read -r kind runtime rbuild < <(python3 -I - "$RUNNER_TEMP/runtimes.json" "$2" "$sdk" <<'PY'
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("cs", "scripts/ci-simulator.py"); cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
rts = json.load(open(sys.argv[1]))["runtimes"]
rt, kind = cs.pick(rts, sys.argv[2], sys.argv[3])
print(kind, rt, next(r["buildversion"] for r in rts if r["identifier"] == rt))
PY
)
  xb=$(xcodebuild -version | awk '/Build version/{print $3}')
  {
    echo "KIND=$kind"; echo "RUNTIME=$runtime"; echo "RUNTIME_BUILD=$rbuild"; echo "XCODE_BUILD=$xb"
    echo "SIMPREFIX=probe-sim-$kind-$rbuild-$xb-"
    echo "SIMKEY=probe-sim-$kind-$rbuild-$xb-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  } | tee -a "$GITHUB_ENV"
  ;;
seed)
  t0=$SECONDS
  udid=$(bash .github/scripts/boot-sim.sh probe "$KIND" "$RUNTIME") || { echo "first boot failed"; exit 1; }
  say "seed: first boot $((SECONDS - t0)) s (boot-sim.sh), load $(load)"
  dir="$HOME/Library/Developer/CoreSimulator/Devices/$udid"
  t0=$SECONDS; xcrun simctl shutdown "$udid"; say "seed: shutdown $((SECONDS - t0)) s"
  mkdir -p "$SET"; t0=$SECONDS; cp -Rp "$dir" "$SET/$udid"; say "seed: copy $((SECONDS - t0)) s"
  say "seed: device dir $(du -sk "$SET/$udid" | cut -f1) KiB raw"
  t0=$SECONDS; size=$(tar -C "$SET" -cf - . | zstd -T0 -q -c | wc -c); say "seed: tar+zstd $((size / 1048576)) MiB in $((SECONDS - t0)) s"
  du -sk "$SET/$udid"/data/* "$SET/$udid"/data/Library/* "$SET/$udid"/data/private/var/* 2>/dev/null | sort -n | tail -8
  # A second boot on the same runner, from the original, for (d) without the restore.
  t0=$SECONDS; xcrun simctl boot "$udid"; xcrun simctl bootstatus "$udid" >/dev/null; say "seed: second boot of the same device $((SECONDS - t0)) s, load $(load)"
  xcrun simctl shutdown "$udid"
  ;;
clone)
  ls "$SET"; xcrun simctl --set "$SET" list devices
  src=$(ls "$SET" | grep -E '^[0-9A-F-]{36}$' | head -1)
  t0=$SECONDS; udid=$(xcrun simctl --set "$SET" clone "$src" gatefold-probe "$HOME/Library/Developer/CoreSimulator/Devices")
  say "restore: clone into the default set $((SECONDS - t0)) s -> $udid"
  xcrun simctl list devices | grep gatefold-probe || { say "restore: the clone is NOT listed in the default set"; exit 1; }
  t0=$SECONDS; xcrun simctl boot "$udid"; xcrun simctl bootstatus "$udid" >/dev/null; code=$?
  say "restore: boot of the restored clone $((SECONDS - t0)) s (bootstatus exit $code), load $(load)"
  xcrun simctl list devices | grep gatefold-probe
  echo "UDID=$udid" >> "$GITHUB_ENV"
  ;;
restart)
  src=$(ls "$SET" | grep -E '^[0-9A-F-]{36}$' | head -1); new=$(uuidgen)
  dst="$HOME/Library/Developer/CoreSimulator/Devices/$new"
  cp -Rp "$SET/$src" "$dst"; plutil -replace UDID -string "$new" "$dst/device.plist"; plutil -replace name -string gatefold-probe-moved "$dst/device.plist"
  xcrun simctl list devices | grep -c gatefold-probe-moved && say "restart path: listed without a restart" || say "restart path: not listed until the service restarts"
  t0=$SECONDS; killall -9 com.apple.CoreSimulator.CoreSimulatorService; sleep 5; xcrun simctl list devices >/dev/null
  say "restart path: service restart and first listing $((SECONDS - t0)) s"
  xcrun simctl list devices | grep gatefold-probe-moved || { say "restart path: still not listed"; exit 1; }
  t0=$SECONDS; xcrun simctl boot "$new"; xcrun simctl bootstatus "$new" >/dev/null
  say "restart path: boot $((SECONDS - t0)) s, load $(load)"
  ;;
keep)
  # Idle until the 1-minute load is under 60, at most 600 s, so the first boot's background work finishes first.
  t0=$SECONDS
  while (( SECONDS - t0 < 600 )); do l=$(sysctl -n vm.loadavg | awk '{print int($2)}'); (( l < 60 )) && break; sleep 10; done
  say "seed: idled $((SECONDS - t0)) s until load $(load)"
  plan="$RUNNER_TEMP/ci-simulator/$2.plan"
  kind=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["kind"])' "$plan")
  runtime=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["runtime"])' "$plan")
  t0=$SECONDS; xcrun simctl shutdown "$UDID"; say "seed: shutdown $((SECONDS - t0)) s"
  mkdir -p ~/warm-sim; cp -Rp "$HOME/Library/Developer/CoreSimulator/Devices/$UDID" ~/warm-sim/
  echo "$UDID $kind $runtime" > ~/warm-sim/warm.txt
  say "seed: kept $(du -sk ~/warm-sim | cut -f1) KiB"
  ;;
esac
