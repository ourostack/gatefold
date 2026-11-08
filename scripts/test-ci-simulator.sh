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
case "$*" in
  "--sdk iphonesimulator --show-sdk-version") echo 27.1 ;;
  "simctl list runtimes -j")
    n=$(( $(cat "$FAKE/runtime-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/runtime-calls"
    avail=true; for u in $FAKE_UNAVAIL_CALLS; do [ "$u" = "$n" ] && avail=false; done
    echo "{\"runtimes\":[{\"platform\":\"iOS\",\"isAvailable\":$avail,\"version\":\"27.1\",\"identifier\":\"iOS-27-1\",\"supportedDeviceTypes\":[{\"name\":\"iPad Pro 13-inch (M5)\",\"identifier\":\"iPad-Pro-13\"}]}]}" ;;
  "simctl list devices -j")
    list=""; for u in $(cat "$FAKE/udids" 2>/dev/null); do list="$list${list:+,}{\"udid\":\"$u\",\"state\":\"Booted\"}"; done
    echo "{\"devices\":{\"iOS-27-1\":[$list]}}" ;;
  "simctl shutdown "*|"simctl delete "*|"simctl erase "*|"simctl boot "*|"simctl bootstatus "*) echo "$*" >> "$FAKE/simctl" ;;
  *) echo "fake xcrun: unexpected $*" >&2; exit 64 ;;
esac
FAKE
cat > "$work/boot-sim.sh" <<'FAKE'
#!/usr/bin/env bash
# Fake boot-sim.sh: a new UDID each call; exits $FAKE_BOOT_EXIT.
n=$(( $(cat "$FAKE/boots" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/boots"
echo "booting $1 ($2 on $3)" >&2
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
# `erase`, the cold step's erase: runtime listing 1 is the check; 2 is the fresh device's pick; 3 its check.
erase_case() {
  local case_dir="$work/erase-$1"; mkdir -p "$case_dir/fake" "$case_dir/tmp"; : > "$case_dir/env"
  echo "dev0" > "$case_dir/fake/udids"
  printf '{"kind": "iPad-Pro-13", "runtime": "iOS-27-1", "prefix": "iPad Pro 13-inch", "sdk": "27.1"}' > "$case_dir/tmp/plan.json"
  mkdir -p "$case_dir/tmp/ci-simulator"; cp "$case_dir/tmp/plan.json" "$case_dir/tmp/ci-simulator/gatefold-ipad.plan"
  local got code
  got="$(PATH="$work/bin:$PATH" FAKE="$case_dir/fake" FAKE_UNAVAIL_CALLS="$2" FAKE_BOOT_EXIT=0 \
    CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" RUNNER_TEMP="$case_dir/tmp" GITHUB_ENV="$case_dir/env" \
    python3 -I "$here/ci-simulator.py" erase gatefold-ipad dev0 2>"$case_dir/err")"; code=$?
  if [ "$code" = "$3" ] && [ "${got:--}" = "$4" ]; then echo "ok   erase: $1"; else
    echo "FAIL erase: $1: exit $code (want $3), printed '${got}' (want $4)"; tail -5 "$case_dir/err"; fails=$((fails + 1)); fi
  # Whatever device it ends on was erased (never a fresh one tested unerased).
  if [ "$3" = 0 ] && ! grep -qx "simctl erase $4" "$case_dir/fake/simctl"; then
    echo "FAIL erase: $1: $4 was never erased"; fails=$((fails + 1)); fi
}
erase_case "the erased device is fine" "" 0 dev0
erase_case "the runtime went during the erase (gatefold#71)" "1" 0 dev1
erase_case "it stays gone" "1 2 3" 1 -
echo "$fails failed"
[ "$fails" = 0 ]
