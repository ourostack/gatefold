#!/usr/bin/env bash
# Offline test of scripts/ci-simulator.py start/wait against a fake xcrun and a fake boot-sim.sh: no simulator.
#   bash scripts/test-ci-simulator.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
mkdir -p "$work/bin"

cat > "$work/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
# Fake xcrun. Runtime listing number N (1-based) shows iOS 27.1 unavailable when N is in $FAKE_UNAVAIL_CALLS.
# ci-simulator.py waits 1 s for a listing here (CI_SIMULATOR_LIST_TIMEOUT), so a hanging one times out.
case "$*" in
  "--sdk iphonesimulator --show-sdk-version") echo 27.1 ;;
  "simctl list runtimes -j")
    n=$(( $(cat "$FAKE/runtime-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/runtime-calls"
    # Listing N hangs, then gives up with no answer, when N is in $FAKE_HANG_CALLS.
    for u in ${FAKE_HANG_CALLS:-}; do [ "$u" = "$n" ] && { sleep 3; exit 1; }; done
    avail=true; for u in $FAKE_UNAVAIL_CALLS; do [ "$u" = "$n" ] && avail=false; done
    echo "{\"runtimes\":[{\"platform\":\"iOS\",\"isAvailable\":$avail,\"version\":\"27.1\",\"identifier\":\"iOS-27-1\",\"supportedDeviceTypes\":[{\"name\":\"iPad Pro 13-inch (M5)\",\"identifier\":\"iPad-Pro-13\"}]}]}" ;;
  "simctl runtime list -j")
    # No image listed, so `start` boots at once; with $FAKE_STANDIN, iOS 27.1 is a Ready stand-in that never moves.
    if [ -n "${FAKE_STANDIN:-}" ]; then
      echo '{"a":{"runtimeIdentifier":"iOS-27-1","build":"24A94425","state":"Ready","mountPath":"/Library/Developer/CoreSimulator/Volumes/iOS_24A94425"}}'
    else echo '{}'; fi ;;
  "simctl list devices -j")
    list=""; for u in $(cat "$FAKE/udids" 2>/dev/null); do list="$list${list:+,}{\"udid\":\"$u\",\"state\":\"Booted\"}"; done
    echo "{\"devices\":{\"iOS-27-1\":[$list]}}" ;;
  "simctl bootstatus "*)
    echo "$*" >> "$FAKE/simctl"
    n=$(( $(cat "$FAKE/bootstatus-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/bootstatus-calls"
    for u in ${FAKE_BOOTSTATUS_FAILED_CALLS:-}; do [ "$u" = "$n" ] && { echo "Data Migration Failed"; exit 0; }; done; true ;;
  "simctl shutdown "*)
    echo "$*" >> "$FAKE/simctl"
    # Shutdown N hangs when N is in $FAKE_SHUTDOWN_HANGS; says the device is already shut down in $FAKE_SHUTDOWN_DONE.
    n=$(( $(cat "$FAKE/shutdown-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/shutdown-calls"
    for u in ${FAKE_SHUTDOWN_HANGS:-}; do [ "$u" = "$n" ] && exec /bin/sleep 5; done
    for u in ${FAKE_SHUTDOWN_DONE:-}; do [ "$u" = "$n" ] && { echo "Unable to shutdown device in current state: Shutdown" >&2; exit 149; }; done ;;
  "simctl erase "*)
    n=$(( $(cat "$FAKE/erase-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/erase-calls"
    # Erase N fails as on job 129031300623 when N is in $FAKE_ERASE_405; then it never erased.
    for u in ${FAKE_ERASE_405:-}; do [ "$u" = "$n" ] && { echo "Unable to erase contents and settings in current state: Booted (code=405)" >&2; exit 149; }; done
    echo "$*" >> "$FAKE/simctl" ;;
  "simctl delete "*|"simctl boot "*) echo "$*" >> "$FAKE/simctl" ;;
  "simctl spawn "*)
    echo "$*" >> "$FAKE/simctl"
    # Every spawn hangs when $FAKE_SPAWN_HANGS is set (a starved simulator).
    [ -z "${FAKE_SPAWN_HANGS:-}" ] || exec /bin/sleep 5
    # Every spawn takes $FAKE_SPAWN_SLOW seconds and then works (a loaded simulator: 3 to 9 s each on CI).
    [ -z "${FAKE_SPAWN_SLOW:-}" ] || /bin/sleep "$FAKE_SPAWN_SLOW" ;;
  *) echo "fake xcrun: unexpected $*" >&2; exit 64 ;;
esac
FAKE
cat > "$work/boot-sim.sh" <<'FAKE'
#!/usr/bin/env bash
# Fake boot-sim.sh: a new UDID each call; exits $FAKE_BOOT_EXIT.
n=$(( $(cat "$FAKE/boots" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/boots"
echo "booting $1 ($2 on $3)" >&2
# Boot N hangs, holding a child (as bootstatus and the watchdog are), when N is $FAKE_BOOT_HANG_ON.
if [ "$n" = "${FAKE_BOOT_HANG_ON:-}" ]; then /bin/sleep 60 & echo $! > "$FAKE/child"; wait; fi
# Like the real one's watchdog: a sleep that outlives this script holding stderr (only the subshell is killed).
( sleep 20; echo "watchdog" >&2 ) >/dev/null & w=$!; sleep 1; kill "$w"
[ "${FAKE_BOOT_EXIT:-0}" = 0 ] || exit "$FAKE_BOOT_EXIT"
echo "dev$n" >> "$FAKE/udids"; echo "dev$n"
FAKE
chmod +x "$work/bin/xcrun" "$work/boot-sim.sh"

fails=0
# check <name> <unavailable listing calls> <boot exit> <expected exit> <expected UDID or -> <expected text>
check() {
  local case_dir="$work/$1"; mkdir -p "$case_dir/fake" "$case_dir/tmp"
  local began; began=$(date +%s)
  : > "$case_dir/env"
  out="$(PATH="$work/bin:$PATH" FAKE="$case_dir/fake" FAKE_UNAVAIL_CALLS="$2" FAKE_BOOT_EXIT="$3" \
    CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" RUNNER_TEMP="$case_dir/tmp" GITHUB_ENV="$case_dir/env" \
    bash -c 'python3 -I "$0/ci-simulator.py" start gatefold-ipad "iPad Pro 13-inch" && python3 -I "$0/ci-simulator.py" wait gatefold-ipad "iPad Pro 13-inch" 30' "$here" 2>&1)"
  local code=$?
  local took=$(( $(date +%s) - began ))
  local got; got="$(sed -n 's/^UDID=//p' "$case_dir/env")"
  # Well under the fake watchdog's 20 s: nothing waits on a process boot-sim.sh left behind.
  if [ "$code" = "$4" ] && [ "${got:--}" = "$5" ] && grep -qF -- "$6" <<<"$out" && [ "$took" -lt 15 ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: exit $code (want $4), UDID ${got:--} (want $5), text '$6', took ${took}s (want under 15)"; echo "$out" | tail -15; fails=$((fails + 1))
  fi
}
check "booted and its runtime is there" "" 0 0 dev1 "booted, and its runtime is available"
check "the runtime goes after the boot, a fresh device has it (gatefold#71)" "2" 0 0 dev2 "Booted, but its runtime iOS-27-1 is no longer available"
check "the runtime stays gone" "2 3 4" 0 1 - "booted again, but its runtime iOS-27-1 is no longer available"
check "the boot fails" "" 3 1 - "boot-sim.sh exited 3"
# A runtime on its stand-in mount that never moves to its cryptex: no boot at all, and the runner is named (#469).
FAKE_STANDIN=1 CI_SIMULATOR_SETTLE_LIMIT=1 check "the runtime never settles" "" 0 1 - "::error title=The runner, not the app::the runtime never settled"
if [ ! -e "$work/the runtime never settles/fake/boots" ]; then echo "ok   wait: an unsettled runtime is never booted"
else echo "FAIL wait: an unsettled runtime was booted"; fails=$((fails + 1)); fi
# `erase`, the cold step's erase: runtime listing 1 is the check; 2 is the fresh device's pick; 3 its check.
erase_case() {
  local case_dir="$work/erase-$1"; mkdir -p "$case_dir/fake" "$case_dir/tmp"; : > "$case_dir/env"
  echo "dev0" > "$case_dir/fake/udids"
  printf '{"kind": "iPad-Pro-13", "runtime": "iOS-27-1", "prefix": "iPad Pro 13-inch", "sdk": "27.1"}' > "$case_dir/tmp/plan.json"
  mkdir -p "$case_dir/tmp/ci-simulator"; cp "$case_dir/tmp/plan.json" "$case_dir/tmp/ci-simulator/gatefold-ipad.plan"
  local got code
  got="$(PATH="$work/bin:$PATH" FAKE="$case_dir/fake" FAKE_UNAVAIL_CALLS="$2" FAKE_BOOT_EXIT=0 FAKE_BOOTSTATUS_FAILED_CALLS="${5:-}" \
    FAKE_HANG_CALLS="${6:-}" CI_SIMULATOR_LIST_TIMEOUT=1 CI_SIMULATOR_BUDGET="${7:-inf}" \
    CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" RUNNER_TEMP="$case_dir/tmp" GITHUB_ENV="$case_dir/env" \
    python3 -I "$here/ci-simulator.py" erase gatefold-ipad dev0 2>"$case_dir/err")"; code=$?
  if [ "$code" = "$3" ] && [ "${got:--}" = "$4" ] && grep -qF -- "${8:-}" "$case_dir/err"; then echo "ok   erase: $1"; else
    echo "FAIL erase: $1: exit $code (want $3), printed '${got}' (want $4)"; tail -5 "$case_dir/err"; fails=$((fails + 1)); fi
  # Whatever device it ends on was erased (never a fresh one tested unerased).
  if [ "$3" = 0 ] && ! grep -qx "simctl erase $4" "$case_dir/fake/simctl"; then
    echo "FAIL erase: $1: $4 was never erased"; fails=$((fails + 1)); fi
}
erase_case "the erased device is fine" "" 0 dev0
erase_case "the runtime went during the erase (gatefold#71)" "1" 0 dev1
erase_case "it stays gone" "1 2 3" 1 -
erase_case "bootstatus says Failed, yet the device is Booted (#57)" "" 0 dev1 "1"
erase_case "bootstatus fails on the fresh device too" "" 1 - "1 2"
erase_case "the check's listing times out on a healthy device: kept, not replaced (run 42502520118)" "" 0 dev0 "" "1 2"
erase_case "one listing times out, the next answers: the answer decides" "" 0 dev0 "" "1"
# The step's budget (CI_SIMULATOR_BUDGET, less ci-simulator.py's 30 s margin) is a few seconds: never killed by the step.
# Out of time, the step fails with its own warning unless the device was last seen ready (it never is by then).
erase_case "the step's time runs out mid-check: fails, with its own warning" "" 1 - "" "1 2" 32 "Simulator check out of time"
erase_case "the runtime went but no time is left for a fresh device: fails, with its own warning" "1" 1 - "" "" 40 "Simulator check out of time"
# A device that passed its check has its first-boot jobs removed (gatefold#209), on the wait path and the erase path.
labels="$here/../.github/scripts/quiet-sim.labels"
want=$(grep -cvE '^[[:space:]]*(#|$)' "$labels")
if grep -qx "simctl spawn dev1 launchctl remove com.apple.PosterBoard" "$work/booted and its runtime is there/fake/simctl" \
   && [ "$(grep -c 'launchctl remove' "$work/booted and its runtime is there/fake/simctl")" = "$want" ]; then
  echo "ok   wait: the booted device's $want first-boot jobs are removed (gatefold#209)"
else echo "FAIL wait: the booted device was not quieted"; fails=$((fails + 1)); fi
if grep -qx "simctl spawn dev2 launchctl remove com.apple.PosterBoard" "$work/the runtime goes after the boot, a fresh device has it (gatefold#71)/fake/simctl" \
   && ! grep -q "simctl spawn dev1 " "$work/the runtime goes after the boot, a fresh device has it (gatefold#71)/fake/simctl"; then
  echo "ok   wait: the fresh device is quieted, the replaced one never (gatefold#209)"
else echo "FAIL wait: the fresh device was not quieted"; fails=$((fails + 1)); fi
if grep -qx "simctl spawn dev0 launchctl remove com.apple.PosterBoard" "$work/erase-the erased device is fine/fake/simctl"; then
  echo "ok   erase: the erased device's first-boot jobs are removed (gatefold#209)"
else echo "FAIL erase: the erased device was not quieted"; fails=$((fails + 1)); fi
if ! grep -q "launchctl remove" "$work/the boot fails/fake/simctl" 2>/dev/null; then
  echo "ok   wait: a device that failed is never quieted"
else echo "FAIL wait: a failed device was quieted"; fails=$((fails + 1)); fi
# Every spawn hangs: quieting stops at its limit and the device still passes.
qd="$work/quiet-hangs"; mkdir -p "$qd/fake" "$qd/tmp"; : > "$qd/env"
out="$(PATH="$work/bin:$PATH" FAKE="$qd/fake" FAKE_UNAVAIL_CALLS="" FAKE_BOOT_EXIT=0 FAKE_SPAWN_HANGS=1 CI_SIMULATOR_QUIET_LIMIT=3 \
  CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" RUNNER_TEMP="$qd/tmp" GITHUB_ENV="$qd/env" \
  bash -c 'python3 -I "$0/ci-simulator.py" start gatefold-ipad "iPad Pro 13-inch" && python3 -I "$0/ci-simulator.py" wait gatefold-ipad "iPad Pro 13-inch" 30' "$here" 2>&1)"; code=$?
if [ "$code" = 0 ] && grep -q "^UDID=dev1$" "$qd/env" && grep -qF "stopped at its limit" <<<"$out"; then
  echo "ok   wait: quieting that hangs stops at its limit, and the device still passes"
else echo "FAIL wait: hanging quieting: exit $code"; echo "$out" | tail -5; fails=$((fails + 1)); fi
# Every spawn is slow but works: all the jobs are still removed inside the limit, since the removals run side by side.
# One at a time, 42 removals of 1 s each would stop at a 20 s limit after about 20, and the jobs it never reached run
# through the tests (in 10% of shards on CI, which then ran at a load over 400 in 42% of cases; gatefold#404).
qd="$work/quiet-slow"; mkdir -p "$qd/fake" "$qd/tmp"; : > "$qd/env"
out="$(PATH="$work/bin:$PATH" FAKE="$qd/fake" FAKE_UNAVAIL_CALLS="" FAKE_BOOT_EXIT=0 FAKE_SPAWN_SLOW=1 CI_SIMULATOR_QUIET_LIMIT=20 \
  CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" RUNNER_TEMP="$qd/tmp" GITHUB_ENV="$qd/env" \
  bash -c 'python3 -I "$0/ci-simulator.py" start gatefold-ipad "iPad Pro 13-inch" && python3 -I "$0/ci-simulator.py" wait gatefold-ipad "iPad Pro 13-inch" 60' "$here" 2>&1)"; code=$?
if [ "$code" = 0 ] && grep -qF "removed $want of $want first-boot jobs" <<<"$out" && ! grep -qF "stopped at its limit" <<<"$out"; then
  echo "ok   wait: on a slow simulator every first-boot job is still removed, inside the limit"
else echo "FAIL wait: slow quieting: exit $code"; echo "$out" | grep -E "quiet" | tail -3; fails=$((fails + 1)); fi
# No labels file: not quieted, and the device still passes.
if python3 -I -c 'import importlib.util as u, pathlib, sys
s = u.spec_from_file_location("cs", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m)
m.quiet("dev9", pathlib.Path("/nonexistent/quiet-sim.labels"))' "$here/ci-simulator.py" 2>&1 | grep -qF "dev9 not quieted"; then
  echo "ok   no labels file: not quieted, no error"
else echo "FAIL no labels file"; fails=$((fails + 1)); fi
# The wait path's fresh device: boot-sim.sh hangs. Its whole process group is ended at the timeout (not only its
# bash, which left its children running), and the timeout reported is the one that applied. With less left than one
# boot attempt, no fresh device is tried, and it says so.
# gone <pid>: the process has exited. A zombie counts as exited: in a container such as swift:6.2 PID 1 is Actions'
# `tail -f /dev/null`, which never reaps, so a killed orphan stays a zombie and `kill -0` still finds it (job
# 129026427008). Reads /proc where there is one (Linux, with no procps), else ps (macOS).
gone() {
  local s
  if [ -d /proc/self ]; then
    [ -r "/proc/$1/stat" ] || return 0
    s="$(sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f1)"
  else
    s="$(ps -o stat= -p "$1" 2>/dev/null)" || return 0
  fi
  case "$s" in Z*|"") return 0 ;; *) return 1 ;; esac
}
fresh_case() {
  local d="$work/fresh-$1"; mkdir -p "$d/fake" "$d/tmp"; : > "$d/env"
  local out code
  out="$(PATH="$work/bin:$PATH" FAKE="$d/fake" FAKE_UNAVAIL_CALLS="2" FAKE_BOOT_HANG_ON=2 CI_SIMULATOR_BUDGET=42 \
    CI_SIMULATOR_RETRY_RESERVE=5 CI_SIMULATOR_BOOT_ATTEMPT="$2" CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" \
    RUNNER_TEMP="$d/tmp" GITHUB_ENV="$d/env" bash -c 'python3 -I "$0/ci-simulator.py" start gatefold-ipad "iPad Pro 13-inch" \
    && python3 -I "$0/ci-simulator.py" wait gatefold-ipad "iPad Pro 13-inch" 30' "$here" 2>&1)"; code=$?
  local alive=no; [ -s "$d/fake/child" ] && ! gone "$(cat "$d/fake/child")" && alive=yes
  if [ "$code" = 1 ] && grep -qE -- "$3" <<<"$out" && [ "$alive" = no ]; then echo "ok   wait: $1"; else
    echo "FAIL wait: $1: exit $code (want 1), text /$3/, its child still running: $alive"; echo "$out" | tail -6; fails=$((fails + 1)); fi
}
fresh_case "the fresh device hangs: its whole process group ended, the timeout that applied reported" 3 \
  "the fresh device did not boot within [0-9]+ s"
fresh_case "less left than one boot attempt: no fresh device, and it says so" 60 \
  "only [0-9]+ s left, less than one boot attempt \\(60 s\\), so no fresh device"

# gatefold#137 (job 129031300623): a shutdown that hung, then an erase that failed 405, still passed as erased. Any
# erase call that does not finish or fails now fails the erase: a fresh device, erased, or the step fails.
FAKE_SHUTDOWN_HANGS="1" CI_SIMULATOR_SHUTDOWN_TIMEOUT=1 erase_case "the shutdown hangs: not erased, so a fresh device, erased (gatefold#137)" "" 0 dev1
# Shutdown 2 is the quiet one before the old device is deleted; 3 is the fresh device's.
FAKE_SHUTDOWN_HANGS="1 3" CI_SIMULATOR_SHUTDOWN_TIMEOUT=1 erase_case "the fresh device's shutdown hangs too: fails, no app code ran" "" 1 - "" "" "" "simctl shutdown hung past 1 s. No app code ran"
FAKE_ERASE_405="1" erase_case "the erase fails 405: not erased, so a fresh device, erased (gatefold#137)" "" 0 dev1
FAKE_ERASE_405="1 2" erase_case "the fresh device's erase fails 405 too: fails, no app code ran" "" 1 - "" "" "" "simctl erase exited 149. No app code ran"
FAKE_SHUTDOWN_DONE="1" erase_case "the device was already shut down: erased as usual" "" 0 dev0

# The real boot-sim.sh against a fake xcrun. Bootstatus call N hangs when N is in $FAKE_HANGS; a device in
# $FAKE_NO_BOOT never comes up. Its limits are cut to seconds and `sleep` caps at 3 s; killall and xcodebuild are
# fakes, so nothing touches this machine's simulators.
real="$work/real"; mkdir -p "$real/bin"
cat > "$real/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
state() { cat "$FAKE/state-$1" 2>/dev/null || echo Shutdown; }
case "$1 $2" in
  "simctl create") n=$(( $(cat "$FAKE/created" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/created"; echo "dev$n" ;;
  "simctl boot") echo "$*" >> "$FAKE/boots"
    for u in ${FAKE_NO_BOOT:-}; do [ "$u" = "$3" ] && exit 0; done
    for u in ${FAKE_BOOTING:-}; do [ "$u" = "$3" ] && { echo Booting > "$FAKE/state-$3"; exit 0; }; done
    echo Booted > "$FAKE/state-$3" ;;
  "simctl shutdown") [ "$3" = all ] || echo Shutdown > "$FAKE/state-$3"; echo "shutdown $3" >> "$FAKE/calls" ;;
  "simctl delete") echo "delete $3" >> "$FAKE/calls" ;;
  # The warm device's clone out of its own set (gatefold#533); fails when $FAKE_CLONE_FAILS is set.
  "simctl --set") echo "set $4 $5 into $7" >> "$FAKE/calls"
    [ "$4" = clone ] || { echo "fake xcrun: unexpected $*" >&2; exit 64; }
    [ -z "${FAKE_CLONE_FAILS:-}" ] || { echo "Invalid device: $5" >&2; exit 148; }
    [ -z "${FAKE_CLONE_NOISY:-}" ] || { echo "note: cloned"; echo 0A1B2C3D-0000-4000-8000-00000000000F; exit 0; }
    echo warm1 ;;
  "simctl bootstatus")
    n=$(( $(cat "$FAKE/bootstatus" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/bootstatus"
    echo "bootstatus $3${4:+ $4}" >> "$FAKE/calls"
    for u in ${FAKE_HANGS:-}; do [ "$u" = "$n" ] && { echo "Monitoring boot status for $3."; exec /bin/sleep 30; }; done
    # Call N hangs, and leaves a child behind that holds its output for 60 s and writes "Failed" into it 4 s in (after
    # its own call has been cut off and read), when N is in $FAKE_ORPHAN_HANGS.
    for u in ${FAKE_ORPHAN_HANGS:-}; do [ "$u" = "$n" ] && { ( /bin/sleep 4; echo "Data Migration Failed (orphan of call $n)"; exec /bin/sleep 56 ) &
      echo "Monitoring boot status for $3."; exec /bin/sleep 30; }; done
    # Call N reports a failed migration, then hangs (cut off by its slice) when N is in $FAKE_FAILED_HANGS.
    for u in ${FAKE_FAILED_HANGS:-}; do [ "$u" = "$n" ] && { echo "Data Migration Failed"; exec /bin/sleep 30; }; done
    # A device that never comes up never answers bootstatus either.
    for u in ${FAKE_NO_BOOT:-}; do [ "$u" = "$3" ] && { echo "Monitoring boot status for $3."; exec /bin/sleep 30; }; done
    for u in ${FAKE_BOOTSTATUS_EXITS:-}; do [ "$u" = "$n" ] && { echo "Unable to boot: the service went away."; exit 1; }; done
    [ -e "$FAKE/state-$3" ] && echo Booted > "$FAKE/state-$3"
    echo "Device already booted, nothing to do." ;;
  "simctl list")
    if [ "${3:-}" = devices ] && [ "${4:-}" = -j ]; then
      n=$(( $(cat "$FAKE/lists" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/lists"
      for u in ${FAKE_LIST_HANGS:-}; do [ "$u" = "$n" ] && exec /bin/sleep 30; done
      list=""; for f in "$FAKE"/state-*; do [ -e "$f" ] || continue; u="${f##*/state-}"
        list="$list${list:+,}{\"udid\":\"$u\",\"state\":\"$(state "$u")\"}"; done
      echo "{\"devices\":{\"iOS-27-1\":[$list]}}"
    fi ;;
  *) echo "fake xcrun: unexpected $*" >&2; exit 64 ;;
esac
FAKE
# Whole seconds cap at 3 (the service restart's 20 s); fractions (within's 0.2 s poll) pass through.
printf '#!/usr/bin/env bash\ncase "$1" in *.*) exec /bin/sleep "$1" ;; esac\nexec /bin/sleep "$(( $1 > 3 ? 3 : $1 ))"\n' > "$real/bin/sleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$real/bin/killall"
printf '#!/usr/bin/env bash\nexit 0\n' > "$real/bin/xcodebuild"
chmod +x "$real/bin/"*
# real_case <name> <hanging bootstatus calls> <devices that never boot> <expected UDID> <expected log text> \
#   <text the log must not have> [a line the fake's call log must have]. $FAKE_LIST_HANGS: device listings that hang.
# Under /bin/bash, macOS's 3.2, unless $BOOT_SIM_BASH names another (Linux's bash 5 in the job `CI scripts, offline`).
real_case() {
  local d="$real/$(echo "$1" | tr -c 'a-zA-Z0-9\n' -)"; mkdir -p "$d/fake"
  local began got code took; began=$(date +%s)
  got="$(PATH="$real/bin:$PATH" FAKE="$d/fake" FAKE_HANGS="$2" FAKE_NO_BOOT="$3" BOOT_SIM_BOOTSTATUS_LIMIT="${CASE_LIMIT:-2}" \
    BOOT_SIM_BOOTSTATUS_SLICE="${CASE_SLICE:-}" BOOT_SIM_NOBOOT_LIMIT="${CASE_NOBOOT:-}" BOOT_SIM_CONFIRM_LIMIT=2 \
    BOOT_SIM_RECHECK_LIMIT=2 BOOT_SIM_LIST_LIMIT=2 BOOT_SIM_WARM_SET="${CASE_WARM:-}" \
    BOOT_SIM_DEVICES="$d/devices" "${BOOT_SIM_BASH:-/bin/bash}" "${BOOT_SIM_UNDER_TEST:-$here/../.github/scripts/boot-sim.sh}" gatefold-ipad iPad-Pro-13 iOS-27-1 2>"$d/err")"; code=$?
  took=$(( $(date +%s) - began ))
  # The script's last background process is gone once it returns (nothing of a watchdog left to act).
  if [ "$code" = 0 ] && [ "$got" = "$4" ] && grep -qF -- "$5" "$d/err" && ! grep -qF -- "$6" "$d/err" \
     && { [ -z "${7:-}" ] || grep -qxF -- "$7" "$d/fake/calls"; } && [ "$took" -lt 40 ]; then
    echo "ok   boot-sim.sh: $1"
  else
    echo "FAIL boot-sim.sh: $1: exit $code (want 0), printed '$got' (want $4), log has '$5', not '$6'${7:+, calls have '$7'}, took ${took}s"
    tail -8 "$d/err"; fails=$((fails + 1))
  fi
}
# gatefold#132 (job 128961815446): bootstatus hung on a device that was up; the old watchdog shut it down.
real_case "bootstatus hangs on a booted device, its second bootstatus finishes: that device (gatefold#132)" \
  "1" "" dev1 "dev1 is booted; its second bootstatus finished" "did not boot"
# Listed Booted while the migration still runs (#57): the second bootstatus hangs too, so not that device.
real_case "bootstatus hangs, and again on the second: shut down, the next attempt's device (#57)" \
  "1 2" "" dev2 "dev1 is listed Booted, but its second bootstatus did not finish clean" "dev2 is booted; its second" "shutdown dev1"
real_case "bootstatus hangs on a device that never booted: shut down, the next attempt's device" \
  "1" "dev1" dev2 "dev1 never booted" "dev1 is booted" "shutdown dev1"
# A device listing that does not answer (run 42502520118): after a clean bootstatus it does not throw the device away;
# after a hang it is asked once more, and if it still does not answer the device is taken as not booted.
FAKE_LIST_HANGS="1" real_case "a clean bootstatus, then the listing hangs: that device, and it says so" \
  "" "" dev1 "dev1: bootstatus finished clean; the device listing did not answer" "did not boot"
FAKE_LIST_HANGS="1" real_case "bootstatus hangs, the listing hangs once, then answers Booted: rechecked, that device" \
  "1" "" dev1 "dev1 is booted; its second bootstatus finished" "state unknown"
FAKE_LIST_HANGS="1 2" real_case "bootstatus hangs, the listing hangs twice: state unknown, shut down, the next device" \
  "1" "" dev2 "dev1: state unknown (the device listing did not answer twice); taken as not booted" "dev1 never booted" "shutdown dev1"
# Bootstatus exits non-zero (no "Failed") and the listing does not answer, as when CoreSimulatorService is failing:
# not trusted, so not that device.
FAKE_BOOTSTATUS_EXITS="1" FAKE_LIST_HANGS="1" real_case "bootstatus exits 1, then the listing hangs: not that device" \
  "" "" dev2 "dev1: bootstatus exited 1 and the device listing did not answer; taken as not booted" "dev1: bootstatus finished clean"
# bootstatus missed the end of the boot (7 of 41 slow boots on 2026-11-11 waited out 420 s on a ready device): asked
# again after one slice, it answers, so that device, without the hung-device path's second bootstatus.
CASE_LIMIT=8 CASE_SLICE=1 real_case "bootstatus gives no answer in its first slice, the next answers: that device, no recheck" \
  "1" "" dev1 "dev1: bootstatus gave no answer in a 1 s slice" "second bootstatus"
# Only the first ask boots (-b); the next only waits, so it can't boot again a device whose first boot failed.
CASE_LIMIT=8 CASE_SLICE=1 real_case "only the first slice passes -b; a slice that answered logs how long bootstatus took" \
  "1" "" dev1 "dev1: bootstatus finished after" "second bootstatus" "bootstatus dev1"
[ "$(head -1 "$real/only-the-first-slice-passes--b--a-slice-that-answered-logs-how-long-bootstatus-took/fake/calls" 2>/dev/null)" = "bootstatus dev1 -b" ] \
  && echo "ok   boot-sim.sh: the first ask passes -b" || { echo "FAIL boot-sim.sh: the first ask did not pass -b"; fails=$((fails + 1)); }
# A killed bootstatus whose child still holds its output must not hold the boot (gatefold#227, probe 43007631651:
# 60 s slices took 79 and 96 s). Before the fix this case waited out the child's 60 s and failed the 40 s bound. The
# child's late "Failed" belongs to the call that was cut off: it must not reach a later call's output and reject dev1.
FAKE_ORPHAN_HANGS="1" CASE_LIMIT=8 CASE_SLICE=1 real_case "a cut-off slice leaves a child holding its output: the next slice still runs at once" \
  "" "" dev1 "dev1: bootstatus finished after" "second bootstatus"
# Calls 3 to 5 hang too, so a later call is running when the child writes.
FAKE_ORPHAN_HANGS="1" CASE_LIMIT=20 CASE_SLICE=1 real_case "a cut-off slice's child writes Failed later: kept out of later calls' output" \
  "2 3 4 5" "" dev1 "dev1: bootstatus finished after" "did not boot"
# #57: a slice printed Failed and was cut off; the next one exits 0. Not that device.
FAKE_FAILED_HANGS="1" CASE_LIMIT=8 CASE_SLICE=1 real_case "a slice says Failed and is cut off, the next exits 0: not that device (#57)" \
  "" "" dev2 "attempt 1: dev1 did not boot" "dev1: bootstatus finished clean"
# A device that never came up (listed Shutdown, or here not listed at all) is given up on once NOBOOT_LIMIT passes, not at BOOTSTATUS_LIMIT.
CASE_LIMIT=30 CASE_SLICE=1 CASE_NOBOOT=2 real_case "a device not listed past its no-boot limit: given up early, the next device" \
  "" "dev1" dev2 "dev1 never booted: listed Missing" "dev1 is booted" "shutdown dev1"
# One still Booting at that point is slow, not dead (gatefold#198): it keeps slicing and passes when bootstatus answers.
FAKE_BOOTING="dev1" CASE_LIMIT=30 CASE_SLICE=1 CASE_NOBOOT=2 real_case "a device still Booting past its no-boot limit: kept, that device" \
  "1 2 3 4" "" dev1 "dev1: bootstatus finished after" "never booted"
# The early listing must fit inside the limit; when it can't, the old path decides (here, "never booted" at the limit).
CASE_LIMIT=4 CASE_SLICE=1 CASE_NOBOOT=1 real_case "no room for the early listing: the limit's own path decides" \
  "" "dev1" dev2 "dev1 never booted" "listed Missing" "shutdown dev1"
# A warm device restored from the Actions cache (gatefold#533) is cloned into the default set and booted first; with
# none for this device type and runtime, a clone that fails, or a boot that doesn't finish in its short limit, the job
# boots a new device exactly as it does with no cache: a cache miss never fails the boot.
warm_set() { mkdir -p "$real/warm-$1/W1"; echo "W1 $2" > "$real/warm-$1/warm.txt"; echo "$real/warm-$1"; }
CASE_WARM="$(warm_set hit "iPad-Pro-13 iOS-27-1")" real_case "a warm device for this type and runtime: cloned and booted, no new device" \
  "" "" warm1 "warm: warm1 booted" "a new device" "set clone W1 into $real/a-warm-device-for-this-type-and-runtime--cloned-and-booted--no-new-device/devices"
[ ! -e "$real/a-warm-device-for-this-type-and-runtime--cloned-and-booted--no-new-device/fake/created" ] \
  && echo "ok   boot-sim.sh: a warm device that boots creates no other" || { echo "FAIL boot-sim.sh: a warm device that booted still created one"; fails=$((fails + 1)); }
CASE_WARM="$(warm_set other "iPhone-Duo iOS-27-1")" real_case "the warm set holds another device type: a new device, as with no cache" \
  "" "" dev1 "warm: $real/warm-other holds no iPad-Pro-13 on iOS-27-1; a new device" "cloned"
CASE_WARM="$(warm_set old "iPad-Pro-13 iOS-27-0")" real_case "the warm set holds another runtime: a new device, as with no cache" \
  "" "" dev1 "holds no iPad-Pro-13 on iOS-27-1; a new device" "cloned"
CASE_WARM="$real/warm-missing" real_case "the cache missed (no warm set restored): a new device, as with no cache" \
  "" "" dev1 "holds no iPad-Pro-13 on iOS-27-1; a new device" "cloned"
FAKE_CLONE_FAILS=1 CASE_WARM="$(warm_set clonefails "iPad-Pro-13 iOS-27-1")" real_case "the clone fails: a new device, as with no cache" \
  "" "" dev1 "warm: cloning W1 failed" "warm1"
# The clone boots as any device does (gatefold#198). One never listed (gone at the 180 s listing) is deleted and a new
# device boots.
CASE_LIMIT=12 CASE_SLICE=2 CASE_NOBOOT=1 CASE_WARM="$(warm_set noboot "iPad-Pro-13 iOS-27-1")" real_case \
  "the warm clone never comes up: deleted at the early listing, a new device" \
  "" "warm1" dev1 "warm: warm1 failed or never came up; deleted, a new device" "no second device" "delete warm1"
# One whose bootstatus said Failed is a failed boot, however its slice ended: deleted, a new device.
FAKE_FAILED_HANGS=1 CASE_WARM="$(warm_set failed "iPad-Pro-13 iOS-27-1")" real_case "the warm clone's boot said Failed: deleted, a new device" \
  "" "" dev1 "warm: warm1 failed or never came up; deleted, a new device" "warm: warm1 booted" "delete warm1"
# One whose bootstatus hangs while it is listed Booted gets the recheck, as a first boot does, and passes.
CASE_WARM="$(warm_set hangs "iPad-Pro-13 iOS-27-1")" real_case "the warm clone's bootstatus hangs, listed Booted: rechecked and kept" \
  "1" "" warm1 "warm1 is booted; its second bootstatus finished" "a new device"
# One still Booting past the first slice keeps going in the next ones, and passes.
FAKE_BOOTING=warm1 CASE_LIMIT=6 CASE_SLICE=1 CASE_WARM="$(warm_set booting "iPad-Pro-13 iOS-27-1")" real_case \
  "the warm clone is still Booting after a slice: it keeps its limit and boots" "1" "" warm1 "warm: warm1 booted" "a new device"
for c in the-warm-clone-s-bootstatus-hangs--listed-Booted--rechecked-and-kept the-warm-clone-is-still-Booting-after-a-slice--it-keeps-its-limit-and-boots; do
  if [ ! -e "$real/$c/fake/created" ] && ! grep -q "delete warm1" "$real/$c/fake/calls" 2>/dev/null; then echo "ok   boot-sim.sh: $c: no other device"
  else echo "FAIL boot-sim.sh: $c: another device was created or the clone deleted"; fails=$((fails + 1)); fi
done
# One still coming up when its whole limit runs out is shut down and the boot fails there: no second device beside it,
# whose storm doubled the clone's (gatefold#198). The listing is asked, hangs or not.
for hang in "" 1; do
  d="$real/warm-out-of-time-$hang"; mkdir -p "$d/fake"
  got="$(PATH="$real/bin:$PATH" FAKE="$d/fake" FAKE_HANGS="1" FAKE_BOOTING=warm1 FAKE_LIST_HANGS="$hang" BOOT_SIM_BOOTSTATUS_LIMIT=2 \
    BOOT_SIM_CONFIRM_LIMIT=2 BOOT_SIM_RECHECK_LIMIT=2 BOOT_SIM_LIST_LIMIT=2 BOOT_SIM_WARM_SET="$(warm_set "oot$hang" "iPad-Pro-13 iOS-27-1")" \
    BOOT_SIM_DEVICES="$d/devices" "${BOOT_SIM_BASH:-/bin/bash}" "${BOOT_SIM_UNDER_TEST:-$here/../.github/scripts/boot-sim.sh}" gatefold-ipad iPad-Pro-13 iOS-27-1 2>"$d/err")"; code=$?
  if [ "$code" = 1 ] && [ -z "$got" ] && [ ! -e "$d/fake/created" ] && grep -qxF "shutdown warm1" "$d/fake/calls" \
     && grep -qF "warm: warm1 was still coming up after 2 s; no second device beside it" "$d/err"; then
    echo "ok   boot-sim.sh: a warm clone still coming up at its limit${hang:+ (the listing hangs)}: shut down, no second device, the boot fails"
  else echo "FAIL boot-sim.sh: a warm clone still coming up at its limit${hang:+ (the listing hangs)}: exit $code, printed '$got', created $(cat "$d/fake/created" 2>/dev/null || echo none)"
    tail -6 "$d/err"; fails=$((fails + 1)); fi
done
# A clone that printed more than its UDID made a device anyway: it is deleted, and a new device boots.
FAKE_CLONE_NOISY=1 CASE_WARM="$(warm_set noisy "iPad-Pro-13 iOS-27-1")" real_case "the clone prints more than a UDID: that device deleted, a new device" \
  "" "" dev1 "warm: cloning W1 failed" "cloned as" "delete 0A1B2C3D-0000-4000-8000-00000000000F"
# A limit override: a fraction is rounded down, not a crash; one that is not a number is refused.
fr="$real/fraction"; mkdir -p "$fr/fake"
if got="$(PATH="$real/bin:$PATH" FAKE="$fr/fake" BOOT_SIM_LIST_LIMIT=2.5 BOOT_SIM_BOOTSTATUS_LIMIT= \
   "${BOOT_SIM_BASH:-/bin/bash}" "${BOOT_SIM_UNDER_TEST:-$here/../.github/scripts/boot-sim.sh}" gatefold-ipad iPad-Pro-13 iOS-27-1 2>"$fr/err")" \
   && [ "$got" = dev1 ]; then echo "ok   boot-sim.sh: a fractional or empty limit override means the rounded value or the default"
else echo "FAIL boot-sim.sh: a fractional or empty limit override: printed '$got'"; tail -3 "$fr/err"; fails=$((fails + 1)); fi
mkdir -p "$fr/bad/fake"
PATH="$real/bin:$PATH" FAKE="$fr/bad/fake" BOOT_SIM_LIST_LIMIT=soon "${BOOT_SIM_BASH:-/bin/bash}" "${BOOT_SIM_UNDER_TEST:-$here/../.github/scripts/boot-sim.sh}" \
  gatefold-ipad iPad-Pro-13 iOS-27-1 >/dev/null 2>"$fr/bad/err"; code=$?
if [ "$code" = 2 ] && grep -q "a limit must be a number of seconds, not 'soon'" "$fr/bad/err" && [ ! -e "$fr/bad/fake/created" ]; then
  echo "ok   boot-sim.sh: a limit override that is not a number is refused before any device is made"
else echo "FAIL boot-sim.sh: a non-number limit override: exit $code (want 2)"; tail -3 "$fr/bad/err"; fails=$((fails + 1)); fi
# The watchdog of a bootstatus that finished must not wake: the old one logged a false hang on most boots.
for n in 1 2 3 4 5; do real_case "a clean boot logs no hang (run $n of 5)" "" "" dev1 "Device already booted" "hung"; done

# Every boot keeps quiet-sim.labels' first-boot jobs from starting (gatefold#404): one --disabledJob per label.
labels="$here/../.github/scripts/quiet-sim.labels"
want_jobs=$(grep -cvE '^[[:space:]]*(#|$)' "$labels")
boots="$real/a-clean-boot-logs-no-hang--run-1-of-5-/fake/boots"
if [ "$want_jobs" -gt 0 ] && [ "$(head -1 "$boots" 2>/dev/null | grep -o -- '--disabledJob=[^ ]*' | wc -l | tr -d ' ')" = "$want_jobs" ] \
   && grep -qF -- "--disabledJob=com.apple.PosterBoard" "$boots"; then
  echo "ok   boot-sim.sh: the boot disables all $want_jobs first-boot jobs (gatefold#404)"
else echo "FAIL boot-sim.sh: the boot did not disable the $want_jobs first-boot jobs: $(head -1 "$boots" 2>/dev/null | cut -c1-200)"; fails=$((fails + 1)); fi
nl="$real/no-labels"; mkdir -p "$nl/fake"
if got="$(PATH="$real/bin:$PATH" FAKE="$nl/fake" BOOT_SIM_QUIET_LABELS="$nl/none" BOOT_SIM_BOOTSTATUS_LIMIT=2 BOOT_SIM_LIST_LIMIT=2 \
   "${BOOT_SIM_BASH:-/bin/bash}" "${BOOT_SIM_UNDER_TEST:-$here/../.github/scripts/boot-sim.sh}" gatefold-ipad iPad-Pro-13 iOS-27-1 2>"$nl/err")" \
   && [ "$got" = dev1 ] && [ "$(head -1 "$nl/fake/boots")" = "simctl boot dev1" ] && grep -qF "every first-boot job starts" "$nl/err"; then
  echo "ok   boot-sim.sh: with no labels file it still boots, plainly, and says so"
else echo "FAIL boot-sim.sh: with no labels file: printed '$got', boot '$(head -1 "$nl/fake/boots" 2>/dev/null)'"; tail -3 "$nl/err"; fails=$((fails + 1)); fi
# The cold step's erase boots the same way.
if python3 -I -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
boot = next(a for a, _ in m.ERASE_STEPS if a[0] == "boot")
assert "--disabledJob=com.apple.PosterBoard" in boot and len(boot) == 1 + int(sys.argv[2]), boot' "$here/ci-simulator.py" "$want_jobs"; then
  echo "ok   ci-simulator.py: the erase's boot disables the first-boot jobs too"
else echo "FAIL ci-simulator.py: the erase's boot does not disable the first-boot jobs"; fails=$((fails + 1)); fi

# No retry or service restart shuts down every simulator on the Mac; other agents' simulators share it.
if grep -rqxF "shutdown all" "$real" --include=calls; then
  echo "FAIL boot-sim.sh: a retry ran simctl shutdown all"; fails=$((fails + 1))
else echo "ok   boot-sim.sh: retries shut down only the devices it created"; fi

# An override that is set but empty means the default, not a crash.
if CI_SIMULATOR_BUDGET= CI_SIMULATOR_LIST_TIMEOUT= CI_SIMULATOR_BOOT_ATTEMPT= CI_SIMULATOR_RETRY_RESERVE= \
   python3 -I "$here/ci-simulator.py" --selftest >/dev/null 2>"$work/empty-err"; then echo "ok   empty overrides mean the defaults"
else echo "FAIL empty overrides: $(tail -1 "$work/empty-err")"; fails=$((fails + 1)); fi

echo "$fails failed"
[ "$fails" = 0 ]
