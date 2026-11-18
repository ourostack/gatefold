#!/bin/sh
# Fills the app's Metal shader cache before a shard's tests (gatefold#487). SwiftUI compiles a shader on the main
# thread the first time it draws something new (RenderBox's `MTLCompilerScheduler::buildRequest`), and that compile
# waits on the simulator's MTLCompilerService. On a busy runner its launch went unrun for 40 s and more, main was held
# 35 to 207 s, and the tests' queries timed out (run 44292342494). A compiled shader is kept in the app's cache
# (its data container's Library/Caches), which neither a test's reinstall nor `-GatefoldReset` clears, and a cached
# shader needs no compiler. So one launch here draws the shelf, the zoom into a book, its page with the controls and
# page furniture up, and Fine-Tune, before any test runs. Setup only: it never fails the job, and it ends by its bound.
#   ci-warm-metal.sh <udid> <Gatefold.app> <reader.log> [bound in seconds, default 180]
# <reader.log> is the step's own stream of the app's `reader` lines (ui-tests.yml); its "first page ready" ends the wait.
set -u
udid="$1"
app="$2"
log="$3"
bound="${4:-180}"
id=bot.ouro.gatefold
started=$(date +%s)
note() { echo "$(date -u +%T) warm-metal: $*"; }
if ! xcrun simctl install "$udid" "$app"; then
  note "the install failed; the tests install the app themselves"
  exit 0
fi
from=$(($(wc -l < "$log") + 1))
if ! xcrun simctl launch "$udid" "$id" -GatefoldUITest YES -GatefoldFakeCloud YES -GatefoldSkipWelcome YES \
  -GatefoldSignedIn YES -GatefoldReset YES -GatefoldDownloadAll YES -GatefoldPageFurniture YES -GatefoldShowChrome YES \
  -GatefoldSheet customize -GatefoldOpenBook gutenberg-pride-and-prejudice -GatefoldGoTo 0.31 > /dev/null; then
  note "the launch failed"
  exit 0
fi
ready=false
while [ $(($(date +%s) - started)) -lt "$bound" ]; do
  if tail -n "+$from" "$log" | grep -q "first page ready"; then
    ready=true
    break
  fi
  sleep 1
done
xcrun simctl terminate "$udid" "$id" > /dev/null 2>&1
cache="$(xcrun simctl get_app_container "$udid" "$id" data 2>/dev/null)/Library/Caches/$id/com.apple.metal"
size=$(du -sk "$cache" 2>/dev/null | cut -f1)
note "page ready $ready after $(($(date +%s) - started)) s; Metal cache ${size:-0} KB"
exit 0
