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
  *) echo "fake xcrun: unexpected $*" >&2; exit 64 ;;
esac
FAKE
cat > "$work/boot-sim.sh" <<'FAKE'
#!/usr/bin/env bash
# Fake boot-sim.sh: a new UDID each call; exits $FAKE_BOOT_EXIT.
n=$(( $(cat "$FAKE/boots" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/boots"
echo "booting $1 ($2 on $3)" >&2
[ "${FAKE_BOOT_EXIT:-0}" = 0 ] || exit "$FAKE_BOOT_EXIT"
echo "dev$n" >> "$FAKE/udids"; echo "dev$n"
FAKE
chmod +x "$work/bin/xcrun" "$work/boot-sim.sh"

fails=0
# check <name> <unavailable listing calls> <boot exit> <expected exit> <expected UDID or -> <expected text>
check() {
  local case_dir="$work/$1"; mkdir -p "$case_dir/fake" "$case_dir/tmp"
  : > "$case_dir/env"
  out="$(PATH="$work/bin:$PATH" FAKE="$case_dir/fake" FAKE_UNAVAIL_CALLS="$2" FAKE_BOOT_EXIT="$3" \
    CI_SIMULATOR_BOOT_SIM="$work/boot-sim.sh" RUNNER_TEMP="$case_dir/tmp" GITHUB_ENV="$case_dir/env" \
    bash -c 'python3 -I "$0/ci-simulator.py" start gatefold-ipad "iPad Pro 13-inch" && python3 -I "$0/ci-simulator.py" wait gatefold-ipad "iPad Pro 13-inch" 30' "$here" 2>&1)"
  local code=$?
  local got; got="$(sed -n 's/^UDID=//p' "$case_dir/env")"
  if [ "$code" = "$4" ] && [ "${got:--}" = "$5" ] && grep -qF -- "$6" <<<"$out"; then
    echo "ok   $1"
  else
    echo "FAIL $1: exit $code (want $4), UDID ${got:--} (want $5), text '$6'"; echo "$out" | tail -15; fails=$((fails + 1))
  fi
}
check "booted and its runtime is there" "" 0 0 dev1 "booted, and its runtime is available"
check "the runtime goes after the boot, a fresh device has it (gatefold#71)" "2" 0 0 dev2 "Booted, but its runtime iOS-27-1 is no longer available"
check "the runtime stays gone" "2 3" 0 1 - "booted again, but its runtime iOS-27-1 is no longer available"
check "the boot fails" "" 3 1 - "boot-sim.sh exited 3"
echo "$fails failed"
[ "$fails" = 0 ]
