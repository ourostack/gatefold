#!/bin/sh
# shellcheck disable=SC2016 # $0 and $1 belong to each inner shell, so its script is in single quotes.
# CI only: keep the app's logs from a booted simulator as the tests run (gatefold#72, #76, #357).
#   ci-app-logs.sh <udid>   start the log streams in the background, appending to $RUNNER_TEMP's logs
# Run again after the device is erased or replaced (scripts/ci-bootstrap.py): a stream ends with its device's boot.
# Lines carrying the book's words are dropped; the place log keeps file and progression only.
set -eu
udid="$1"
# The place log: file and progression only, never the book's words.
nohup sh -c 'xcrun simctl spawn "$0" log stream --style compact --predicate "subsystem == \"bot.ouro.gatefold\"" 2>/dev/null \
  | grep --line-buffered -E "place (read|write)|place:|location |reflow|landing|landed|reopen|tapped|warm:|open:|first page|pages:|turn:|spread:|veil:|settle [0-9]|REPRO|snapshot:|back:" \
  | grep --line-buffered -v -E "text:|\] visible|\] anchor[: ]" >> "$1"' "$udid" "$RUNNER_TEMP/place.log" >/dev/null 2>&1 &
# Why the system ended the app, when it did (gatefold#76): runningboardd's lines about it, no page text.
nohup sh -c 'xcrun simctl spawn "$0" log stream --style compact --predicate "process == \"runningboardd\" AND eventMessage CONTAINS \"bot.ouro.gatefold\"" 2>/dev/null \
  | grep --line-buffered -i -E "termin|kill|jetsam|exit|reason|invalidat|memory|highwater|limit" >> "$1"' "$udid" "$RUNNER_TEMP/rb.log" >/dev/null 2>&1 &
# The reader's own lines (launch-jump landings among them; gatefold#72), kept for every shard as Real unfold
# keeps them; lines carrying the page's text are dropped.
nohup sh -c 'xcrun simctl spawn "$0" log stream --style compact --predicate "subsystem == \"bot.ouro.gatefold\" AND category == \"reader\"" 2>/dev/null \
  | grep --line-buffered -v "text:" >> "$1"' "$udid" "$RUNNER_TEMP/reader.log" >/dev/null 2>&1 &
