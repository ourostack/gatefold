#!/usr/bin/env bash
# Releases Gatefold to TestFlight's internal group: archive and export (scripts/package-testflight-ios.sh),
# upload with the App Store Connect API key, wait for processing, attach the build to the internal
# group, set What's New from a file, and check the tester can see it.
#
#   scripts/release-testflight.sh --whats-new notes.txt --tester someone@example.com [--ipa path/Gatefold.ipa] [--out dir] [--dry-run]
#
# --dry-run makes only read-only calls (the app, the group, whether the build is already there, the
# tester) and stops before archiving or uploading.
# --ipa skips the archive and uploads an IPA already exported (it must carry project.yml's build
# number). Every App Store Connect call goes through the desk's redacting client (ASC_TOOL, default
# below), which signs with the key described by apple-distribution-kit's config: no key, token or
# issuer ID is printed or kept here (altool is handed the key ID and issuer ID as arguments; the
# private key stays in its file). Each call's redacted response is
# saved under <out>/asc/.
set -euo pipefail
cd "$(dirname "$0")/.."

ASC_TOOL="${ASC_TOOL:-$HOME/desk/e-reader-apps/pocketbook-companion-app/evidence/testflight/tools/asc.mjs}"
KIT_CONFIG="${APPLE_DISTRIBUTION_KIT_CONFIG:-$HOME/Library/Application Support/AppleDistributionKit/app-store-connect/config.json}"
BUNDLE_ID="bot.ouro.gatefold"
GROUP_NAME="${GATEFOLD_TESTFLIGHT_GROUP:-Gatefold Internal}"

whats_new="" tester="" ipa="" out="" dry_run=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == --dry-run || $# -ge 2 ]] || { echo "$1 needs a value" >&2; exit 2; }
  case "$1" in
    --whats-new) whats_new="$2"; shift 2 ;;
    --tester) tester="$2"; shift 2 ;;
    --ipa) ipa="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
fail() { echo "release: $*" >&2; exit 1; }
[[ -f "$whats_new" ]] || fail "--whats-new must name a file with the tester notes"
[[ -s "$whats_new" ]] || fail "the What's New file is empty"
(( $(wc -m < "$whats_new") <= 4000 )) || fail "What's New is over App Store Connect's 4000 characters"
[[ -n "$tester" ]] || fail "--tester must name the tester whose access is checked"
[[ -f "$ASC_TOOL" ]] || fail "no App Store Connect client at $ASC_TOOL (set ASC_TOOL)"
[[ -f "$KIT_CONFIG" ]] || fail "no apple-distribution-kit config at $KIT_CONFIG"

build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)"
version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
[[ -n "$build" && -n "$version" ]] || fail "could not read the version and build from project.yml"
out="${out:-$HOME/Projects/_artifacts/gatefold-build$build}"
mkdir -p "$out/asc"
echo "release: Gatefold $version ($build) from $(git rev-parse --short HEAD) into $out"

# The key's ID and path, for xcodebuild and altool; read from the kit's config, never printed.
key_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$KIT_CONFIG" "$1"; }
ASC_KEY_ID="$(key_field keyId)"; ASC_ISSUER_ID="$(key_field issuerId)"; ASC_KEY_PATH="$(key_field privateKeyPath)"
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH

# One App Store Connect call: METHOD PATH [asc.mjs args]; the redacted result lands in asc/<name>.json.
asc() {
  local name="$1"; shift
  node "$ASC_TOOL" "$@" --out "$out/asc/$name.json" > /dev/null
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); s=d['status']; print('  %s %s -> %s' % (d['method'], d['url'].split('?')[0], s)); sys.exit(0 if s < 400 else 1)" "$out/asc/$name.json"
}
field() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['response']; print($2)" "$out/asc/$1.json" 2>/dev/null || fail "unexpected App Store Connect answer in $out/asc/$1.json"; }

# 1. The app and its internal group, by name.
asc app GET /v1/apps --q "filter[bundleId]=$BUNDLE_ID" --q "fields[apps]=bundleId"
[[ "$(field app 'len(d["data"])')" != "0" ]] || fail "no app with bundle ID $BUNDLE_ID"
app_id="$(field app 'd["data"][0]["id"]')"
asc group GET /v1/betaGroups --q "filter[app]=$app_id" --q "filter[name]=$GROUP_NAME" --q "fields[betaGroups]=name,isInternalGroup"
[[ "$(field group 'len(d["data"])')" != "0" ]] || fail "no TestFlight group named $GROUP_NAME"
group_id="$(field group 'd["data"][0]["id"]')"

check_tester() {
  asc "$1" GET /v1/betaTesters --q "filter[email]=$tester" --q "filter[betaGroups]=$group_id" --q "fields[betaTesters]=email,state"
  [[ "$(field "$1" 'len(d["data"])')" != "0" ]] || fail "the tester is not in $GROUP_NAME"
}
# 2. Whether App Store Connect already has this build (a rerun after a later step failed).
asc existing GET /v1/builds --q "filter[app]=$app_id" --q "filter[version]=$build" --q "filter[preReleaseVersion.version]=$version" --q "fields[builds]=version,processingState"
if [[ -n "$dry_run" ]]; then
  check_tester tester
  echo "release: dry run: app, group and tester found; build $build $( [[ "$(field existing 'len(d["data"])')" == "0" ]] && echo "not yet uploaded" || echo "already in App Store Connect"). Nothing changed."
  exit 0
fi

# 3. Archive and export, unless an IPA is given.
if [[ -z "$ipa" ]]; then
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "the checkout has changes: release from a clean main"
  GATEFOLD_ARCHIVE_DIR="$out" scripts/package-testflight-ios.sh > "$out/archive.log" 2>&1 || fail "archive or export failed: $out/archive.log"
  git rev-parse HEAD > "$out/source-commit.txt"
  ipa="$out/export/Gatefold.ipa"
fi
[[ -f "$ipa" ]] || fail "no IPA at $ipa"
ipa_build="$(unzip -p "$ipa" 'Payload/*.app/Info.plist' | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || true)"
[[ "$ipa_build" == "$build" ]] || fail "the IPA is build ${ipa_build:-unknown}, project.yml says $build"
shasum -a 256 "$ipa" | tee "$out/Gatefold.ipa.sha256"

# 4. Upload, unless App Store Connect already has this build or an earlier run uploaded it and it
# is still processing (it can take minutes to be listed).
if [[ -f "$out/uploaded-$build" ]]; then
  echo "release: build $build was uploaded by an earlier run; waiting for it"
elif [[ "$(field existing 'len(d["data"])')" == "0" ]]; then
  echo "release: uploading"
  API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")" xcrun altool --upload-app -f "$ipa" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json > "$out/upload.log" 2>&1 \
    || fail "upload failed: $out/upload.log"
  date -u +%FT%TZ > "$out/uploaded-$build"
else
  echo "release: build $build is already in App Store Connect; not uploading again"
fi

# 5. Wait for processing (up to an hour).
state="" build_id=""
for _ in $(seq 1 120); do
  asc build GET /v1/builds --q "filter[app]=$app_id" --q "filter[version]=$build" --q "filter[preReleaseVersion.version]=$version" \
    --q "include=betaBuildLocalizations" --q "fields[builds]=version,processingState,betaBuildLocalizations" > /dev/null || true
  if [[ "$(field build 'len(d["data"])')" != "0" ]]; then
    build_id="$(field build 'd["data"][0]["id"]')"
    state="$(field build 'd["data"][0]["attributes"]["processingState"]')"
    [[ "$state" == "VALID" ]] && break
    [[ "$state" == "FAILED" || "$state" == "INVALID" ]] && fail "App Store Connect processing ended $state"
  fi
  sleep 30
done
[[ "$state" == "VALID" ]] || fail "build $build was not processed within an hour (state: ${state:-not found})"
echo "release: build $build is processed ($build_id)"

# 6. Attach to the internal group, unless it already lists the build (a rerun) or sees every build.
asc group-builds GET "/v1/betaGroups/$group_id/builds" --q "fields[builds]=version" --q "limit=200"
asc group-access GET "/v1/betaGroups/$group_id" --q "fields[betaGroups]=hasAccessToAllBuilds"
if [[ "$(field group-builds "any(x['id']=='$build_id' for x in d['data'])")" == "True" ]]; then
  echo "release: $GROUP_NAME already has build $build"
elif [[ "$(field group-access 'd["data"]["attributes"].get("hasAccessToAllBuilds")')" == "True" ]]; then
  echo "release: $GROUP_NAME sees every build; nothing to attach"
else
python3 -c 'import json,sys; json.dump({"data":[{"type":"builds","id":sys.argv[1]}]}, open(sys.argv[2],"w"))' "$build_id" "$out/asc/body-attach.json"
asc attach POST "/v1/betaGroups/$group_id/relationships/builds" --body "$out/asc/body-attach.json"
fi

# 7. What's New, on the build's en-US localization (made if it isn't there yet).
loc_id="$(field build 'next((x["id"] for x in d.get("included", []) if x["type"]=="betaBuildLocalizations" and x["attributes"]["locale"]=="en-US"), "")')"
if [[ -n "$loc_id" ]]; then
  python3 -c 'import json,sys; json.dump({"data":{"type":"betaBuildLocalizations","id":sys.argv[1],"attributes":{"whatsNew":open(sys.argv[2]).read().strip()}}}, open(sys.argv[3],"w"))' \
    "$loc_id" "$whats_new" "$out/asc/body-whatsnew.json"
  asc whatsnew PATCH "/v1/betaBuildLocalizations/$loc_id" --body "$out/asc/body-whatsnew.json"
else
  python3 -c 'import json,sys; json.dump({"data":{"type":"betaBuildLocalizations","attributes":{"locale":"en-US","whatsNew":open(sys.argv[2]).read().strip()},"relationships":{"build":{"data":{"type":"builds","id":sys.argv[1]}}}}}, open(sys.argv[3],"w"))' \
    "$build_id" "$whats_new" "$out/asc/body-whatsnew.json"
  asc whatsnew POST /v1/betaBuildLocalizations --body "$out/asc/body-whatsnew.json"
fi

# 8. Read back: the group has the build, the notes are his, and the tester is in the group.
if [[ "$(field group-access 'd["data"]["attributes"].get("hasAccessToAllBuilds")')" != "True" ]]; then
  asc readback-group GET "/v1/betaGroups/$group_id/builds" --q "fields[builds]=version" --q "limit=200"
  [[ "$(field readback-group "any(x['id']=='$build_id' for x in d['data'])")" == "True" ]] || fail "the group does not list build $build"
fi
asc readback-notes GET "/v1/builds/$build_id/betaBuildLocalizations"
python3 - "$out/asc/readback-notes.json" "$whats_new" <<'PY' || fail "What's New does not match the file"
import json, sys
d = json.load(open(sys.argv[1]))["response"]["data"]
want = open(sys.argv[2]).read().strip()
sys.exit(0 if any(x["attributes"]["locale"] == "en-US" and (x["attributes"]["whatsNew"] or "").strip() == want for x in d) else 1)
PY
check_tester readback-tester
echo "release: Gatefold $version ($build) is in $GROUP_NAME with its notes, and the tester can see it. Records: $out/asc/"
