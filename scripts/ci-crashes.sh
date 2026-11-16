#!/bin/sh
# Fails the job when the app crashed during its tests, or the system ended it for memory (gatefold#76).
#
# The UI tests no longer terminate an app the system has already ended, so a crash can no longer show up
# as a "Failed to terminate" error. A simulator app's crash report lands on the host Mac, so this checks for one.
#   ci-crashes.sh mark    before the tests: note the time
#   ci-crashes.sh check   after them: copy every Gatefold crash report since the mark to $RUNNER_TEMP/crashes and fail;
#                         also fail on a memory kill in runningboardd's log ($RUNNER_TEMP/rb.log): on a device that is
#                         the reader dying, so it must never pass as "the system ended it in the background".
#                         When every report is the runner failing to read a mapped file back (SIGBUS, KERN_MEMORY_ERROR;
#                         ci-bootstrap.py crash), the error says the runner failed, so rerun-runner.yml reruns the
#                         shard; one report of any other kind keeps them all the app's
set -eu
mark="$RUNNER_TEMP/crash-mark"
reports="$HOME/Library/Logs/DiagnosticReports"
case "${1:-}" in
  mark)
    touch "$mark"
    ;;
  check)
    [ -f "$mark" ] || { echo "no mark: the tests did not start"; exit 0; }
    df -h / "$RUNNER_TEMP" "$HOME/Library/Developer" 2>/dev/null || true
    status=0
    rb="$RUNNER_TEMP/rb.log"
    if [ -f "$rb" ]; then
      # Only an end event (not a jetsam-priority or termination-resistance attribute) whose reason is memory.
      # The simulator rarely enforces memory limits, so this seldom fires on CI; a device would.
      memory="$(grep -E 'Terminating with context|termination reported by|Process exited|[Kk]illed' "$rb" \
        | grep -v -i 'TerminationResistance' \
        | grep -i -E 'domain:jetsam|jetsam\(|highwater|per-process-limit|vm-pageshortage|memory limit|memorystatus' | head -5 || true)"
      if [ -n "$memory" ]; then
        printf '%s\n' "$memory" | while IFS= read -r l; do echo "::error::The system ended the app for memory: $l"; done
        status=1
      else
        echo "no memory kill in runningboardd's log"
      fi
    fi
    out="$RUNNER_TEMP/crashes"
    mkdir -p "$out"
    found="$(find "$reports" -type f -name 'Gatefold*' -newer "$mark" 2>/dev/null || true)"
    if [ -z "$found" ]; then
      echo "no Gatefold crash report since the tests began"
      exit $status
    fi
    here="$(dirname "$0")"
    runner=1
    for f in $found; do
      python3 -I "$here/ci-bootstrap.py" crash "$f" >/dev/null || runner=0
    done
    printf '%s\n' "$found" | while IFS= read -r f; do
      cp "$f" "$out/"
      if [ "$runner" = 1 ]; then
        why="$(python3 -I "$here/ci-bootstrap.py" crash "$f")"
        echo "::error title=The runner, not the app::$(basename "$f"): $why. The runner's disk failed; rerun it on a fresh runner (gatefold#135)."
      else
        why="$(grep -o -E '"(exception|termination)" : \{[^}]*\}' "$f" | tr '\n' ' ' | cut -c1-400 || true)"
        echo "::error::The app crashed during the tests: $(basename "$f") $why"
      fi
    done
    exit 1
    ;;
  *)
    echo "usage: ci-crashes.sh mark|check" >&2
    exit 2
    ;;
esac
