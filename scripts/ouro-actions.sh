#!/usr/bin/env bash
# Gatefold's actions come from one declaration (actions/gatefold.actions.mts) through Ouro UI's generator, which is
# vendored from an ouro-ui-core release by hash. Needs Node 22.18 or later.
#
#   scripts/ouro-actions.sh vendor <tag>      take the generator and its claims from that ouro-ui-core release
#   scripts/ouro-actions.sh generate          write the app's actions from the declaration
#   scripts/ouro-actions.sh check             the vendored files match the release's hashes, and nothing generated has drifted
#   scripts/ouro-actions.sh report [file]     the same check, plus the action claims report CI uploads (default xray-actions/report.json)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIR=tools/ouro-actions
GEN="$DIR/ouro-actions.mts"
DECLARATIONS=actions/gatefold.actions.mts
OUT=actions/generated

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
want() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["files"][sys.argv[2]])' "$DIR/dist-manifest.json" "$1"; }

verify_vendored() {
  local tag file
  tag="$(python3 -I -c 'import json; print(json.load(open("'"$DIR"'/dist-manifest.json"))["coreTag"])')"
  for pair in "ouro-actions.mts:dist/actions/ouro-actions.mts" "actions.claims.json:dist/ax/actions.claims.json"; do
    file="${pair%%:*}"
    [[ "$(sha "$DIR/$file")" == "$(want "${pair#*:}")" ]] || {
      echo "error: $DIR/$file isn't the file in ouro-ui-core $tag. Fix: never edit it; run scripts/ouro-actions.sh vendor $tag." >&2
      exit 1
    }
  done
  echo "ok    $DIR matches ouro-ui-core $tag"
}

case "${1:-}" in
  vendor)
    tag="${2:?usage: scripts/ouro-actions.sh vendor <tag>}"
    gh release download "$tag" --repo ourostack/ouro-ui-core --pattern ouro-actions.mts --pattern actions.claims.json --pattern dist-manifest.json --dir "$DIR" --clobber
    verify_vendored
    ;;
  generate)
    node "$GEN" generate "$DECLARATIONS" "$OUT"
    ;;
  check)
    verify_vendored
    node "$GEN" check "$DECLARATIONS" "$OUT"
    ;;
  report)
    verify_vendored
    node "$GEN" check "$DECLARATIONS" "$OUT" --report "${2:-xray-actions/report.json}" --app "Gatefold" --commit "${GITHUB_SHA:-local}"
    ;;
  *)
    sed -n '2,9p' "$0" >&2
    exit 2
    ;;
esac
