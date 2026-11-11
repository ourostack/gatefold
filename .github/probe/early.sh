#!/usr/bin/env bash
# Probe for gatefold#198 (never merged). Usage:
#   early.sh remove <udid> <label>    one pass of `launchctl remove` over quiet-sim.labels, each call bounded 20 s
#   early.sh during <udid> <flagfile> passes every 10 s from now until <flagfile> exists, then one more
#   early.sh find <udid> <marker>     files in the device newer than <marker> that name a quiet label
set -uo pipefail
L="$(dirname "$0")/../scripts/quiet-sim.labels"
labels() { grep -vE '^\s*(#|$)' "$L"; }
bounded() { python3 -I -c 'import subprocess,sys
try: sys.exit(subprocess.run(sys.argv[2:],stdin=subprocess.DEVNULL,capture_output=True,timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired: sys.exit(124)' "$@"; }
cmd="$1"; shift
case "$cmd" in
remove)
  u="$1" tag="$2" n=0 t=$SECONDS
  for l in $(labels); do bounded 20 xcrun simctl spawn "$u" launchctl remove "$l" && n=$((n+1)); done
  echo "REMOVE $tag $(date -u +%T) removed $n in $((SECONDS-t)) s, load $(sysctl -n vm.loadavg | awk '{print $2}')" ;;
during)
  u="$1" flag="$2" i=0
  while [ ! -e "$flag" ]; do i=$((i+1)); "$0" remove "$u" "pass$i"; sleep 10; done
  "$0" remove "$u" final ;;
find)
  u="$1" marker="$2" d="$HOME/Library/Developer/CoreSimulator/Devices/$1"
  pat=$(labels | head -5 | paste -sd'|' -)
  find "$d" -type f -newer "$marker" 2>/dev/null | while read -r f; do
    if grep -aqE "$pat" "$f" 2>/dev/null; then echo "FOUND ${f#$d/}"; plutil -p "$f" 2>/dev/null | head -40; fi
  done ;;
esac
