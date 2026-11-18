#!/bin/sh
# Fills the app's Metal shader cache before a shard's tests (gatefold#487). SwiftUI compiles a shader on the main
# thread the first time it draws something new (RenderBox's `MTLCompilerScheduler::buildRequest`), and that compile
# waits on the simulator's MTLCompilerService. On a busy runner its launch went unrun for 40 s and more, main was held
# 35 to 207 s, and the tests' queries timed out (run 44292342494). A compiled shader is kept in the app's cache
# (its data container's Library/Caches), which neither the tests' install over this one nor `-GatefoldReset` clears,
# and a cached shader needs no compiler. So one launch here draws the shelf while the books download, then the open
# into a book and its page with the controls, page furniture and Fine-Tune up, before any test runs. It closes the
# app at "first page ready"; anything not drawn by then is compiled by the tests as before. Setup only: it never
# fails the job, and it ends by its bound.
#   ci-warm-metal.sh <udid> <Gatefold.app> <log> [bound in seconds, at most 180]
# <log> gets the app's `reader` lines for this launch only (no page text), apart from the tests' reader.log.
set -u
udid="$1"
app="$2"
log="$3"
bound="${4:-180}"
id=bot.ouro.gatefold
pidf="$log.pid"
started=$(date +%s)
note() { echo "$(date -u +%T) warm-metal: $*"; }
if [ "$bound" -lt 30 ]; then
  note "setup has $bound s left; not warming"
  exit 0
fi
if ! xcrun simctl install "$udid" "$app"; then
  note "the install failed; the tests install the app themselves"
  exit 0
fi
: > "$log"
# The stream's own pid is kept, so both it and its filter end with this script.
# shellcheck disable=SC2016
sh -c 'echo $$ > "$1"; exec xcrun simctl spawn "$0" log stream --style compact \
  --predicate "subsystem == \"bot.ouro.gatefold\" AND category == \"reader\"" 2>/dev/null' "$udid" "$pidf" \
  | grep --line-buffered -v "text:" >> "$log" &
filter=$!
stop() { kill "$(cat "$pidf" 2>/dev/null)" "$filter" 2>/dev/null; }
if ! xcrun simctl launch "$udid" "$id" -GatefoldUITest YES -GatefoldFakeCloud YES -GatefoldSkipWelcome YES \
  -GatefoldSignedIn YES -GatefoldReset YES -GatefoldDownloadAll YES -GatefoldPageFurniture YES -GatefoldShowChrome YES \
  -GatefoldSheet customize -GatefoldOpenBook gutenberg-pride-and-prejudice -GatefoldGoTo 0.31 > /dev/null; then
  note "the launch failed"
  stop
  exit 0
fi
ready=false
while [ $(($(date +%s) - started)) -lt "$bound" ]; do
  if grep -q "first page ready" "$log"; then
    ready=true
    break
  fi
  sleep 1
done
xcrun simctl terminate "$udid" "$id" > /dev/null 2>&1
stop
cache="$(xcrun simctl get_app_container "$udid" "$id" data 2>/dev/null)/Library/Caches/$id/com.apple.metal"
size=$(du -sk "$cache" 2>/dev/null | cut -f1)
note "page ready $ready after $(($(date +%s) - started)) s; Metal cache ${size:-0} KB"
exit 0
