#!/usr/bin/env bash
# Offline test of scripts/ci-publish-testflight.sh's upload step (gatefold#337) against a fake kit, xcodebuild,
# xcodegen, unzip and plutil: no network, no App Store Connect, no secrets.
#   bash scripts/test-ci-publish-testflight.sh
# The fake kit answers the upload with FAKE_UPLOAD_EXIT, FAKE_UPLOAD_STDOUT and FAKE_UPLOAD_STDERR, and a build
# lookup by number with one build in FAKE_PROCESSING (none when it is "none"). Step 5's first App Store Connect call prints "FAKE: reached step 5" and fails, so a run that
# got past the poll is told apart from one that stopped before it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
mkdir -p "$work/bin"
# Stand-ins for the key config's values; none may appear in the script's output or its artifacts.
KEY_ID="FAKEKEYID0123" ISSUER_ID="fake-issuer-0000-1111" KEY_PATH="$work/AuthKey_FAKE.p8"
printf 'fake key\n' > "$KEY_PATH"
printf '{"keyId":"%s","issuerId":"%s","privateKeyPath":"%s"}\n' "$KEY_ID" "$ISSUER_ID" "$KEY_PATH" > "$work/asc.json"
printf 'Fixed a thing.\n' > "$work/whats-new.txt"

cat > "$work/bin/node" <<'FAKE'
#!/usr/bin/env bash
# Fake `node <kit> ...`: the kit's JSON answers.
shift
echo "$*" >> "$FAKE/kit-calls"
case "$1 $2" in
  "asc get")
    case "$*" in
      *"--path /v1/apps "*) echo '{"ok":true,"result":{"data":[{"id":"fake-app"}]}}' ;;
      *"filter[version]="*)
        echo poll >> "$FAKE/polls"
        [ "$FAKE_PROCESSING" = none ] && { echo '{"ok":true,"result":{"data":[]}}'; exit 0; }
        echo "{\"ok\":true,\"result\":{\"data\":[{\"id\":\"fake-build\",\"attributes\":{\"processingState\":\"$FAKE_PROCESSING\",\"uploadedDate\":\"$FAKE_UPLOADED\"}}]}}" ;;
      *"--path /v1/builds "*) echo '{"ok":true,"result":{"data":[]}}' ;;
      *) echo "FAKE: reached step 5" >&2; echo '{"ok":false,"error":"fake"}'; exit 1 ;;
    esac ;;
  "xcode run")
    # The kit's answer carries the argv, key and issuer IDs included, as the real one does.
    jq -n --arg stdout "$FAKE_UPLOAD_STDOUT" --arg stderr "$FAKE_UPLOAD_STDERR" --argjson code "$FAKE_UPLOAD_EXIT" \
      --arg argv "$*" '{ok: ($code == 0), mode: "apply", command: ($argv | split(" ")), exitCode: $code, stdout: $stdout, stderr: $stderr}'
    exit "$FAKE_UPLOAD_EXIT" ;;
  *) echo "fake kit: unexpected $*" >&2; exit 2 ;;
esac
FAKE
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Fake curl for GitHub's attempts API: attempt 1 of run 43318514534 ran 22:18-23:27Z (its own times), and the
# token must be the fake one.
for a in "$@"; do case "$a" in
  "Authorization: Bearer fake-github-token") auth=ok ;;
  */repos/ourostack/gatefold/actions/runs/43318514534/attempts/1) url=ok ;;
esac; done
[ "${auth:-}" = ok ] && [ "${url:-}" = ok ] || { echo "curl: (22) 404" >&2; exit 22; }
echo '{"run_attempt":1,"run_started_at":"2026-11-12T22:17:58Z","updated_at":"2026-11-12T23:27:05Z"}'
FAKE
cat > "$work/bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
# Fake xcodebuild: the archive does nothing; the export writes an IPA where -exportPath says.
while [ $# -gt 0 ]; do
  if [ "$1" = -exportPath ]; then mkdir -p "$2" && echo fake-ipa > "$2/Gatefold.ipa"; fi
  shift
done
FAKE
printf '#!/usr/bin/env bash\ntrue\n' > "$work/bin/xcodegen"
printf '#!/usr/bin/env bash\necho fake-plist\n' > "$work/bin/unzip"
cat > "$work/bin/plutil" <<'FAKE'
#!/usr/bin/env bash
# Fake plutil: the IPA's CFBundleVersion.
cat > /dev/null; echo "$FAKE_BUILD"
FAKE
chmod +x "$work/bin/"*

fails=0
# run <name> <upload exit> <processing state or none> <altool's stderr> [<altool's stdout> [<run attempt>
# [<the listed build's uploadedDate>]]]: runs the publish script; its output is in $work/<name>.
run() {
  local name="$1"
  export FAKE="$work/$name.fake"
  mkdir -p "$FAKE"
  FAKE_UPLOAD_EXIT="$2" FAKE_PROCESSING="$3" FAKE_UPLOAD_STDERR="$4" FAKE_UPLOAD_STDOUT="${5:-}" FAKE_BUILD=28 \
    FAKE_UPLOADED="${7:-2026-11-12T14:28:56-08:00}" PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/$name.github-output" \
    GITHUB_RUN_ATTEMPT="${6:-1}" GITHUB_RUN_ID=43318514534 GITHUB_REPOSITORY=ourostack/gatefold \
    GITHUB_API_URL=https://api.github.com GATEFOLD_GITHUB_TOKEN=fake-github-token \
    APPLE_DISTRIBUTION_KIT_BIN=fake-cli.js APPLE_DISTRIBUTION_KIT_CONFIG="$work/asc.json" \
    GATEFOLD_SIGNING_XCCONFIG=fake.xcconfig GATEFOLD_EXPORT_OPTIONS_PLIST=fake.plist \
    GATEFOLD_WHATS_NEW_FILE="$work/whats-new.txt" GATEFOLD_BUILD_NUMBER=28 GATEFOLD_ARTIFACT_DIR="$work/$name.out" \
    bash "$here/ci-publish-testflight.sh" > "$work/$name" 2>&1
  echo "$?" > "$work/$name.exit"
}
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; sed 's/^/    /' "$work/$2"; fails=$((fails + 1)); }
# expect <name> <description> <grep pattern the output must hold> [<pattern it must not hold>...]
expect() {
  local name="$1" what="$2" want="$3"; shift 3
  grep -q -- "$want" "$work/$name" || { bad "$what (no \"$want\")" "$name"; return; }
  local not
  for not in "$@"; do grep -q -- "$not" "$work/$name" && { bad "$what (has \"$not\")" "$name"; return; }; done
  [ "$(cat "$work/$name.exit")" != 0 ] || { bad "$what (exited 0; step 5's fake should fail it)" "$name"; return; }
  # The key and issuer IDs stay out of the log and the artifacts.
  if grep -rqF -e "$KEY_ID" -e "$ISSUER_ID" -e "$KEY_PATH" -e fake-github-token "$work/$name" "$work/$name.out"; then bad "$what (leaked the key or issuer ID or the GitHub token)" "$name"; return; fi
  ok "$what"
}
polled() { [ -s "$work/$1.fake/polls" ]; }

# Run 43318514534's own stderr, shortened: 500s, then the success line and the delivery UUID. A made-up DEBUG line
# names the fake key and issuer IDs, which the script must scrub from what it prints and keeps.
delivered=$'Running altool at path \'/Applications/Xcode_27.1.app/Contents/SharedFrameworks/ContentDelivery.framework/Resources/altool\'...\n\n2026-11-12 22:27:20.001 DEBUG: [ContentDelivery] API key FAKEKEYID0123, issuer fake-issuer-0000-1111\n2026-11-12 22:27:23.496 ERROR: [ContentDelivery.Uploader.753CC8EBC0] CHANGE UPLOAD STATE TO COMPLETE (UPLOADING ASSET DESCRIPTION): received status code 500; internal server error. (7NF5LZ3LK6IJFLQIDES6CHH43E) (500)\n2026-11-12 22:28:55.029 ERROR: [ContentDelivery.Uploader.753CC8D3C0] CHANGE UPLOAD STATE TO COMPLETE (): received status code 500; internal server error. (PB6O5HGYM44NFZBVFOP7L7QW7U) (500)\n2026-11-12 22:28:55.986  INFO: [ContentDelivery.Uploader.753CC8D3C0] \n==========================================\nUPLOAD SUCCEEDED with no errors\nDelivery UUID: 1ff41b62-e50a-4179-a851-cbd916ff509d\nTransferred 22866961 bytes in 16.193 seconds (1.4MB/s, 11.297Mbps)\n==========================================\n'
failed=$'Running altool at path \'/Applications/Xcode_27.1.app/Contents/SharedFrameworks/ContentDelivery.framework/Resources/altool\'...\n\n2026-11-12 22:27:23.496 ERROR: [ContentDelivery.Uploader.753CC8EBC0] CHANGE UPLOAD STATE TO COMPLETE (UPLOADING ASSET DESCRIPTION): received status code 500; internal server error. (7NF5LZ3LK6IJFLQIDES6CHH43E) (500)\n'
uuid_only=$'2026-11-12 22:28:55.029 ERROR: [ContentDelivery.Uploader.753CC8D3C0] CHANGE UPLOAD STATE TO COMPLETE (): received status code 500; internal server error. (PB6O5HGYM44NFZBVFOP7L7QW7U) (500)\nDelivery UUID: 1ff41b62-e50a-4179-a851-cbd916ff509d\n'
then_failed="$delivered"$'UPLOAD FAILED with 1 error\n'
no_uuid=$'==========================================\nUPLOAD SUCCEEDED with no errors\n==========================================\n'

run delivered-exit-1 1 VALID "$delivered"
expect delivered-exit-1 "UPLOAD SUCCEEDED and a delivery UUID, then exit 1: goes on to the poll, which finds it VALID" \
  "Build 28 is processed (fake-build)" "upload failed"
grep -q "FAKE: reached step 5" "$work/delivered-exit-1" || bad "  ...and reaches step 5" delivered-exit-1
grep -qx 1ff41b62-e50a-4179-a851-cbd916ff509d "$work/delivered-exit-1.out/delivery-uuid.txt" 2>/dev/null \
  || bad "  ...and keeps the delivery UUID" delivered-exit-1

run delivered-exit-1-invalid 1 INVALID "$delivered"
expect delivered-exit-1-invalid "UPLOAD SUCCEEDED, then exit 1, then processing INVALID: fails at the poll" \
  "App Store Connect processing ended INVALID" "upload failed" "is processed"

run failed-exit-1 1 VALID "$failed"
expect failed-exit-1 "no UPLOAD SUCCEEDED and exit 1: fails with \"upload failed\" before the poll" \
  "ci-publish-testflight: upload failed" "is processed"
polled failed-exit-1 && bad "  ...and never polls" failed-exit-1

run no-uuid-exit-1 1 VALID "$no_uuid"
expect no-uuid-exit-1 "UPLOAD SUCCEEDED with no delivery UUID and exit 1: fails with \"upload failed\"" \
  "ci-publish-testflight: upload failed" "is processed"
polled no-uuid-exit-1 && bad "  ...and never polls" no-uuid-exit-1

run uuid-only-exit-1 1 VALID "$uuid_only"
expect uuid-only-exit-1 "a delivery UUID with no UPLOAD SUCCEEDED and exit 1: fails with \"upload failed\"" \
  "ci-publish-testflight: upload failed" "is processed"
polled uuid-only-exit-1 && bad "  ...and never polls" uuid-only-exit-1

run then-failed-exit-1 1 VALID "$then_failed"
expect then-failed-exit-1 "UPLOAD SUCCEEDED and a UUID, then UPLOAD FAILED, and exit 1: fails with \"upload failed\"" \
  "ci-publish-testflight: upload failed" "is processed"
polled then-failed-exit-1 && bad "  ...and never polls" then-failed-exit-1

# Run 43318514534 attempt 2's answers, shortened: App Store Connect refuses build 28 as a duplicate.
duplicate_out='{"product-errors":[{"code":-19232,"message":"The provided entity includes an attribute with a value that has already been used","user-info":{"NSLocalizedFailureReason":"The bundle version must be higher than the previously uploaded version: 28.","iris-code":"ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE","previousBundleVersion":"28"}}]}'
duplicate_err=$'2026-11-12 23:36:45.726 ERROR: [ContentDelivery.Uploader.7C30C713C0] The provided entity includes an attribute with a value that has already been used (-19232) The bundle version must be higher than the previously uploaded version: 28.\n      code : ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE\n   previousBundleVersion : 28\n2026-11-12 23:36:45.730 ERROR: [altool.7C30C713C0] Failed to upload package.\n'

run duplicate-rerun 1 VALID "$duplicate_err" "$duplicate_out" 2
expect duplicate-rerun "a rerun refused as a duplicate of build 28, which App Store Connect lists: goes on to the poll" \
  "Build 28 is processed (fake-build)" "upload failed"
grep -q "FAKE: reached step 5" "$work/duplicate-rerun" || bad "  ...and reaches step 5" duplicate-rerun

run duplicate-rerun-unlisted 1 none "$duplicate_err" "$duplicate_out" 2
expect duplicate-rerun-unlisted "a rerun refused as a duplicate, with no build 28 listed: fails with \"upload failed\"" \
  "ci-publish-testflight: upload failed: App Store Connect already has an upload of build 28 but lists no" "is processed"

run duplicate-first-attempt 1 VALID "$duplicate_err" "$duplicate_out" 1
expect duplicate-first-attempt "a first attempt refused as a duplicate: fails with \"upload failed\" (another run's build)" \
  "ci-publish-testflight: upload failed: App Store Connect already lists" "is processed"

run duplicate-rerun-other-run 1 VALID "$duplicate_err" "$duplicate_out" 2 2026-11-12T15:40:00-08:00
expect duplicate-rerun-other-run "a rerun refused as a duplicate of a build 28 uploaded after attempt 1 ended: fails (another run's build)" \
  "ci-publish-testflight: upload failed: App Store Connect already lists" "is processed"

run duplicate-of-27 1 VALID "${duplicate_err//28/27}" "${duplicate_out//28/27}" 2
expect duplicate-of-27 "a rerun refused as a duplicate of another number: fails with \"upload failed\"" \
  "ci-publish-testflight: upload failed$" "is processed"
polled duplicate-of-27 && bad "  ...and never asks for the build" duplicate-of-27

run delivered-exit-0 0 VALID "$delivered"
expect delivered-exit-0 "exit 0: goes on to the poll as before" "Build 28 is processed (fake-build)" "upload failed" "::warning"

[ "$fails" = 0 ] || { echo "$fails failed (work dir $work)"; exit 1; }
echo "all passed"
