#!/bin/sh
# Fails the job when the app crashed during its tests (gatefold#76).
#
# The UI tests no longer terminate an app the system has already ended, so a crash can no longer show up
# as a "Failed to terminate" error. A simulator app's crash report lands on the host Mac, so this checks for one.
#   ci-crashes.sh mark    before the tests: note the time
#   ci-crashes.sh check   after them: copy every Gatefold crash report since the mark to $RUNNER_TEMP/crashes and fail
set -eu
mark="$RUNNER_TEMP/crash-mark"
reports="$HOME/Library/Logs/DiagnosticReports"
case "${1:-}" in
  mark)
    touch "$mark"
    ;;
  check)
    [ -f "$mark" ] || { echo "no mark: the tests did not start"; exit 0; }
    out="$RUNNER_TEMP/crashes"
    mkdir -p "$out"
    found="$(find "$reports" -type f -name 'Gatefold*' -newer "$mark" 2>/dev/null || true)"
    if [ -z "$found" ]; then
      echo "no Gatefold crash report since the tests began"
      exit 0
    fi
    printf '%s\n' "$found" | while IFS= read -r f; do
      cp "$f" "$out/"
      why="$(grep -o -E '"(exception|termination)" : \{[^}]*\}' "$f" | tr '\n' ' ' | cut -c1-400 || true)"
      echo "::error::The app crashed during the tests: $(basename "$f") $why"
    done
    exit 1
    ;;
  *)
    echo "usage: ci-crashes.sh mark|check" >&2
    exit 2
    ;;
esac
