#!/bin/sh
# Keeps the app's logs as a shard runs, from one `log stream` in the simulator (gatefold#39, #76, #72):
#   ci-app-log.sh <udid> <dir>   run in the background; writes <dir>/place.log, rb.log and reader.log
#   ci-app-log.sh --split <dir>  the same split, of compact log lines on stdin
#   ci-app-log.sh --selftest
# Each `log stream` is one more client the simulator's diagnosticd matches every message against, and the shards
# had three; on a 3-CPU runner diagnosticd was the busiest process in the test step after the app and its tests.
# One stream now carries all three and is split here:
#   place.log   the app's place lines (file and progression only)
#   rb.log      runningboardd's lines about the app: why the system ended it, if it did
#   reader.log  the reader's own lines (launch-jump landings among them), which ci-hang-sample.sh watches
# Lines carrying the page's text are dropped from the app's two (runningboardd's carry none), and so are a
# multi-line message's later lines, which carry no subsystem to judge them by.
set -u

split() {
  dir="$1"
  : >> "$dir/place.log"; : >> "$dir/rb.log"; : >> "$dir/reader.log"
  awk -v place="$dir/place.log" -v rb="$dir/rb.log" -v reader="$dir/reader.log" '
    $4 ~ /^runningboardd\[/ {
      if (tolower($0) ~ /termin|kill|jetsam|exit|reason|invalidat|memory|highwater|limit|launch|webcontent/) { print >> rb; fflush(rb) }
      next
    }
    $4 ~ /^(testmanagerd|SpringBoard)\[/ { print >> rb; fflush(rb); next }
    $4 ~ /^launchd/ { if ($0 ~ /gatefold/) { print >> rb; fflush(rb) }; next }
    $5 !~ /^\[bot\.ouro\.gatefold(:|\])/ || /text:/ { next }
    $5 == "[bot.ouro.gatefold:reader]" { print >> reader; fflush(reader) }
    /place (read|write)|place:|location |reflow|landing|landed|reopen|tapped|warm:|open:|first page|pages:|turn:|spread:|veil:|settle [0-9]|REPRO|snapshot:|back:/ \
      && !/\] visible|\] anchor[: ]/ { print >> place; fflush(place) }'
}

selftest() {
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ci-app-log.XXXXXX")"
  split "$dir" <<'EOF'
2026-11-18 11:27:56.671 Df Gatefold[16112:da4d] [bot.ouro.gatefold:reader] open: positions 12
2026-11-18 11:27:56.672 Df Gatefold[16112:da4d] [bot.ouro.gatefold:reader] text: the words on the page
2026-11-18 11:27:56.673 Df Gatefold[16112:da4d] [bot.ouro.gatefold:place] place write chapter 3 at 0.42
2026-11-18 11:27:56.674 Df Gatefold[16112:da4d] [bot.ouro.gatefold:place] place: anchor text: words
2026-11-18 11:27:56.675 Df Gatefold[16112:da4d] [bot.ouro.gatefold:place] location ] visible 4
2026-11-18 11:27:56.676 Df Gatefold[16112:da4d] [bot.ouro.gatefold:reader] main: held 9400 ms
2026-11-18 11:27:56.677 Df runningboardd[34:9a] [com.apple.runningboard:process] Terminating bot.ouro.gatefold: memory limit
2026-11-18 11:27:56.678 Df runningboardd[34:9a] [com.apple.runningboard:process] Acquiring assertion for bot.ouro.gatefold
2026-11-18 11:27:56.679 Df SpringBoard[20:1] [com.apple.SpringBoard:x] open: bot.ouro.gatefold place write
EOF
  want_reader="2026-11-18 11:27:56.671 Df Gatefold[16112:da4d] [bot.ouro.gatefold:reader] open: positions 12
2026-11-18 11:27:56.676 Df Gatefold[16112:da4d] [bot.ouro.gatefold:reader] main: held 9400 ms"
  want_place="2026-11-18 11:27:56.671 Df Gatefold[16112:da4d] [bot.ouro.gatefold:reader] open: positions 12
2026-11-18 11:27:56.673 Df Gatefold[16112:da4d] [bot.ouro.gatefold:place] place write chapter 3 at 0.42"
  want_rb="2026-11-18 11:27:56.677 Df runningboardd[34:9a] [com.apple.runningboard:process] Terminating bot.ouro.gatefold: memory limit
2026-11-18 11:27:56.679 Df SpringBoard[20:1] [com.apple.SpringBoard:x] open: bot.ouro.gatefold place write"
  fail=0
  [ "$(cat "$dir/reader.log")" = "$want_reader" ] || { echo "reader.log:"; cat "$dir/reader.log"; fail=1; }
  [ "$(cat "$dir/place.log")" = "$want_place" ] || { echo "place.log:"; cat "$dir/place.log"; fail=1; }
  [ "$(cat "$dir/rb.log")" = "$want_rb" ] || { echo "rb.log:"; cat "$dir/rb.log"; fail=1; }
  [ "$fail" = 0 ] && echo "ci-app-log.sh selftest: ok"
  return "$fail"
}

case "${1:-}" in
  --selftest) selftest ;;
  --split) split "$2" ;;
  *)
    xcrun simctl spawn "$1" log stream --style compact --predicate \
      'subsystem == "bot.ouro.gatefold" OR process == "runningboardd" OR process == "testmanagerd" OR (process BEGINSWITH "launchd" AND eventMessage CONTAINS "gatefold") OR (process == "SpringBoard" AND (eventMessage CONTAINS[c] "terminat" OR eventMessage CONTAINS "bot.ouro.gatefold"))' \
      2> /dev/null | split "$2"
    ;;
esac
