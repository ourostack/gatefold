#!/usr/bin/env bash
# run.sh <udid> <derived-data> <out-dir> <display>: runs each scenario in .github/jank/names.tsv (JankRuns, from gen.py)
# while one display is recorded (simctl records one display at a time), one folder per scenario.
set -uo pipefail
udid=$1 dd=$2 out=$3 display=$4
only="${JANK_ONLY:-}"
# Every journey runs; the job fails afterwards if any of them failed (an assertion, a dragcheck, a crash or the time limit).
failed=() ran=0
while IFS=$'\t' read -r name fn; do
  [ -z "$name" ] && continue
  [[ -n "$only" && ",$only," != *",$name,"* ]] && continue
  dir="$out/$name"; mkdir -p "$dir"
  echo "::group::$name"; ran=$((ran + 1))
  if [ "$display" = default ]; then
    xcrun simctl io "$udid" recordVideo --codec=h264 --force "$dir/video.mp4" 2> "$dir/rec.log" &
  else
    xcrun simctl io "$udid" recordVideo --display="$display" --codec=h264 --force "$dir/video.mp4" 2> "$dir/rec.log" &
  fi
  rec=$!
  sleep 2
  python3 -c 'import time; print("%.3f" % time.time())' > "$dir/rec-start.txt"
  start=$SECONDS
  ( xcodebuild test-without-building -project Gatefold.xcodeproj -scheme Gatefold \
      -destination "platform=iOS Simulator,id=$udid" -only-testing:"GatefoldUITests/JankRuns/$fn" \
      -derivedDataPath "$dd" -resultBundlePath "$dir/run.xcresult" > "$dir/xcodebuild.log" 2>&1 ) &
  tp=$!
  limited=0
  while kill -0 $tp 2>/dev/null; do
    if (( SECONDS - start > ${JANK_LIMIT:-420} )); then echo "limit: $name"; limited=1; kill $tp; pkill -f "xcodebuild test-without-building" || true; break; fi
    sleep 2
  done
  wait $tp; rc=$?; echo "test exit $rc after $((SECONDS - start)) s"
  if (( rc != 0 || limited )); then failed+=("$name (exit $rc$( (( limited )) && echo ", time limit"))"); fi
  kill -INT "$rec" 2>/dev/null; wait "$rec" 2>/dev/null
  cat "$dir/rec.log"
  # The driver's step markers are XCTest activities: "t = 1.23s JANK <epoch> begin <step>".
  grep -oE "JANK [0-9.]+ .*" "$dir/xcodebuild.log" | sort -u -k2,2n > "$dir/steps.log"
  mkdir -p "$dir/att"
  xcrun xcresulttool export attachments --path "$dir/run.xcresult" --output-path "$dir/att" > /dev/null 2>&1 || echo "no attachments exported"
  grep -E "JANK|error:|Test Case" "$dir/xcodebuild.log" | grep -vE "JANK [0-9.]+ (begin|end) (wait|watch)" | head -60
  echo "::endgroup::"
done < .github/jank/names.tsv
if (( ran == 0 )); then echo "::error title=Jank journey failed::no journey ran"; exit 1; fi
if (( ${#failed[@]} )); then
  for f in "${failed[@]}"; do echo "::error title=Jank journey failed::$f"; done
  exit 1
fi
echo "every journey passed"
