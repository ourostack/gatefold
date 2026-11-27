#!/bin/bash
# Scratch proof for spike 01 (never merged): does an EPUB handed to Gatefold through the system's open route reach
# the shelf, once, within 3 s? Host side: puts a public-domain book in the Files app's "On My iPhone" storage, opens
# it with `simctl openurl` (Launch Services picks the app that claims EPUB), reads the shelf's own index for the count
# and takes a screenshot after each hand-off.
# Usage: open-in-probe.sh <udid> <Gatefold.app> <out dir>
set -u
udid=$1; app=$2; out=$3
mkdir -p "$out"
book="$PWD/Gatefold/Resources/SampleBooks/frankenstein.epub"
xcrun simctl install "$udid" "$app"
data=$(xcrun simctl get_app_container "$udid" bot.ouro.gatefold data)
index="$data/Library/Application Support/Gatefold/library.json"
count() { python3 -I -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(0)' "$index"; }

# The Files app's local storage ("On My iPhone"), where a person's own download would sit.
groups=$(xcrun simctl get_app_container "$udid" com.apple.DocumentsApp groups 2>/dev/null || true)
echo "Files groups: $groups"
local_storage=$(echo "$groups" | awk '/LocalStorage/ {print $2}' | head -1)
if [ -n "$local_storage" ]; then
  target="$local_storage/File Provider Storage/Frankenstein.epub"
  mkdir -p "$(dirname "$target")"
else
  target="$out/Frankenstein.epub"
fi
cp "$book" "$target"
echo "book at: $target"

xcrun simctl launch "$udid" bot.ouro.gatefold -GatefoldUITest YES -GatefoldFakeCloud YES -GatefoldReset YES -GatefoldNoLatency YES
sleep 20
xcrun simctl io "$udid" screenshot "$out/probe-00-before.png"
echo "books before: $(count)"

hand_off() {
  local n=$1 start now
  start=$(python3 -I -c 'import time; print(time.time())')
  xcrun simctl openurl "$udid" "file://$target"; echo "openurl $n exit $?"
  for _ in $(seq 1 40); do
    now=$(python3 -I -c 'import time; print(time.time())')
    if [ "$(count)" -ge 1 ] && [ "$n" = 1 ]; then break; fi
    [ "$n" != 1 ] && python3 -I -c "import sys; sys.exit(0 if $now - $start > 3 else 1)" && break
    sleep 0.25
  done
  python3 -I -c "print('hand-off $n: books $(count) after', round($now - $start, 2), 's')"
  sleep 1
  xcrun simctl io "$udid" screenshot "$out/probe-0$n-after-open-in.png"
}
hand_off 1
sleep 6
hand_off 2
echo "books after both: $(count)"
xcrun simctl spawn "$udid" log show --last 2m --style compact --predicate 'subsystem BEGINSWITH "bot.ouro.gatefold"' 2>/dev/null | grep -iE "open|import|receive|inbox" | head -20 || true
xcrun simctl terminate "$udid" bot.ouro.gatefold || true
