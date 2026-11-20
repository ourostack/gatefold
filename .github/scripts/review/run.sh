#!/usr/bin/env bash
# Review branch only (never merged): run one reviewer test on a local simulator with the screen recorded.
# Build 25's CI run.sh, made local for build 46, kept for build 47: no job deadline; the work dir is $WORK, not $RUNNER_TEMP.
# usage: run.sh <tag> <Class/testMethod> <limit seconds> [ENV=VAL ...]
# Needs UDID, XCTESTRUN, OUT, WORK; DISPLAYS (space-separated simctl display ids, or "default");
# HUB (the DeviceHub helper) on the Duo, for the hinge and per-display screenshots; POSE=<DeviceHub button> sets the
# hinge before the test.
set -uo pipefail
tag="$1" test="$2" limit="$3"; shift 3
dir="$OUT/$tag"
mkdir -p "$dir" "$WORK/xcr"
pose=""
for kv in "$@"; do
  case "$kv" in POSE=*) pose="${kv#POSE=}" ;; *) export "TEST_RUNNER_$kv" ;; esac
done
export TEST_RUNNER_TASTE_SHOTS="$dir" TEST_RUNNER_R2_SHOTS="$dir"
echo "$(date -u +%T) $tag: $test limit ${limit}s env: $*" | tee -a "$OUT/runs.log"
watch=""
if [ -n "${HUB:-}" ]; then
  export TEST_RUNNER_TASTE_HUB=1
  "$HUB" dump > "$dir/devicehub-dump.txt" 2>&1
  if [ -n "$pose" ]; then "$HUB" press "$pose" >> "$dir/devicehub.log" 2>&1; sleep 6; fi
  ( n=1
    while :; do
      if [ -f "$dir/req-$n" ]; then
        p="$(cat "$dir/req-$n")"; echo "$(date -u +%T) req $n $p" >> "$dir/devicehub.log"
        case "$p" in
          SHOT:*) for d in 1 3; do xcrun simctl io "$UDID" screenshot --display=$d "$dir/hub-${p#SHOT:}-display$d.png" >/dev/null 2>&1; done ;;
          *) "$HUB" press "$p" >> "$dir/devicehub.log" 2>&1 ;;
        esac
        echo done > "$dir/ack-$n"; n=$((n+1))
      fi
      sleep 0.3
    done ) &
  watch=$!
fi
recs=()
for d in ${DISPLAYS:-default}; do
  if [ "$d" = default ]; then
    xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$dir/screen.mp4" 2> "$dir/rec-default.err" &
  else
    xcrun simctl io "$UDID" recordVideo --codec=h264 --display="$d" --force "$dir/screen-display$d.mp4" 2> "$dir/rec-display$d.err" &
  fi
  recs+=($!)
  sleep 1
done
echo "$(python3 -c "import time; print(round(time.time(), 2))") recorders ${recs[*]} started" > "$dir/rec.start"
sleep 2
until=$(( $(date +%s) + limit ))
python3 -I scripts/ci-within.py --until "$until" -- xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
  -destination "id=$UDID" "-only-testing:GatefoldUITests/$test" \
  -resultBundlePath "$WORK/xcr/$tag.xcresult" > "$WORK/xcr/$tag.raw.log" 2>&1
status=$?
for r in "${recs[@]}"; do kill -INT "$r" 2>/dev/null; done
for r in "${recs[@]}"; do wait "$r" 2>/dev/null; done
if [ -n "$watch" ]; then kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null; fi
# The kept log: results, the reviewer's R2 lines and error locations, with any assertion text withheld.
grep -E "Test Case .*(started|passed|failed|skipped)|TEST (EXECUTE )?(SUCCEEDED|FAILED)|^R2 |\.swift:[0-9]+: error|error: |Restarting after unexpected exit|crash" "$WORK/xcr/$tag.raw.log" \
  | awk '{ if (match($0, /XCTAssert[A-Za-z]* failed/)) $0 = substr($0, 1, RSTART + RLENGTH - 1) " (text withheld)"; print }' > "$dir/test.log"
grep -E "Test Case .*(passed|failed|skipped)" "$dir/test.log" | tail -3
echo "$(date -u +%T) $tag: exit $status" | tee -a "$OUT/runs.log"
exit 0
