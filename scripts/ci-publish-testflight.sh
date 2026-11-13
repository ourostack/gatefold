#!/usr/bin/env bash
# CI half of the TestFlight release (.github/workflows/testflight.yml): picks the next build number,
# archives and exports with the long-lived signing identity the workflow installed, uploads, waits
# for App Store Connect to process the build, then hands it to Gatefold Internal with What's New
# through apple-distribution-kit and checks the tester can see it.
#
# Inputs (environment):
#   APPLE_DISTRIBUTION_KIT_BIN     the pinned kit's dist/cli.js
#   APPLE_DISTRIBUTION_KIT_CONFIG  the App Store Connect key config the workflow wrote
#   GATEFOLD_SIGNING_XCCONFIG, GATEFOLD_EXPORT_OPTIONS_PLIST  written by `signing profiles`
#   GATEFOLD_WHATS_NEW_FILE        the tester notes (at most 4000 characters)
#   GATEFOLD_BUILD_NUMBER          optional override; otherwise App Store Connect's highest + 1
#   GATEFOLD_TESTFLIGHT_TESTER     optional; the tester whose access is checked (else any tester)
#   GATEFOLD_ARTIFACT_DIR          where every App Store Connect answer and log is kept
#
# No key, token, issuer ID or certificate is printed: the kit redacts its own output, altool gets
# the key file by path (its argv is dropped from altool-upload.json), tester answers are kept only
# as counts, and xcodebuild signs with the imported identity without Apple's servers.
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="distribution/apple-distribution.json"
BUNDLE_ID="bot.ouro.gatefold"
GROUP_NAME="Gatefold Internal"
# Builds 1-20 were released by hand from a Mac; CD never reuses or goes below them.
BUILD_FLOOR=20
out="${GATEFOLD_ARTIFACT_DIR:-$PWD/build/ci-testflight}"
mkdir -p "$out"

fail() { echo "ci-publish-testflight: $*" >&2; exit 1; }
kit() { node "$APPLE_DISTRIBUTION_KIT_BIN" "$@"; }
# One App Store Connect GET to stdout; on failure, says which path failed and the kit's redacted error.
asc_get() {
  local body
  body="$(kit asc get "$@" --config "$APPLE_DISTRIBUTION_KIT_CONFIG" --json)" \
    || { printf '%s\n' "$body" | jq -c '.error // .' >&2 || true; echo "ci-publish-testflight: App Store Connect GET failed: $*" >&2; return 1; }
  printf '%s\n' "$body"
}

# Seconds since 1970 for an ISO 8601 time, with Z or an offset (App Store Connect writes -08:00; GitHub writes Z).
iso_epoch='def epoch: capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")
  | (.t + "Z" | fromdateiso8601) - (if .z == "Z" then 0 else (if .z[0:1] == "-" then -1 else 1 end) * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) end);'
# True when the time ($1, App Store Connect's uploadedDate) falls inside this step ("Archive, upload and publish to
# Gatefold Internal") in an earlier attempt of this workflow run. The step's own times, not the run's: the publish
# job can queue behind another run's publish, and only while the step runs does it hold the publish group.
uploaded_in_earlier_attempt() {
  local at="$1" attempts="${GITHUB_RUN_ATTEMPT:-1}" n
  [[ -n "$at" && "$attempts" =~ ^[0-9]+$ && -n "${GATEFOLD_GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" \
    && -n "${GITHUB_RUN_ID:-}" ]] || return 1
  for (( n = 1; n < attempts; n++ )); do
    curl -fsS -H "Authorization: Bearer $GATEFOLD_GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
      "${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$n/jobs?per_page=100" \
      | jq -e --arg at "$at" "$iso_epoch"' ($at | epoch) as $t
          | any(.jobs[]? | select(.name == "Publish to Gatefold Internal") | .steps[]?
                | select(.name == "Archive, upload and publish to Gatefold Internal" and .started_at != null and .completed_at != null);
              $t >= (.started_at | epoch) and $t <= (.completed_at | epoch))' \
      > /dev/null 2>&1 && return 0
  done
  return 1
}

for v in APPLE_DISTRIBUTION_KIT_BIN APPLE_DISTRIBUTION_KIT_CONFIG GATEFOLD_SIGNING_XCCONFIG GATEFOLD_EXPORT_OPTIONS_PLIST GATEFOLD_WHATS_NEW_FILE; do
  [[ -n "${!v:-}" ]] || fail "$v is not set"
done
[[ -s "$GATEFOLD_WHATS_NEW_FILE" ]] || fail "the What's New file is empty"
(( $(wc -m < "$GATEFOLD_WHATS_NEW_FILE") <= 4000 )) || fail "What's New is over App Store Connect's 4000 characters"

key_id="$(jq -er .keyId "$APPLE_DISTRIBUTION_KIT_CONFIG")"
issuer_id="$(jq -er .issuerId "$APPLE_DISTRIBUTION_KIT_CONFIG")"
key_path="$(jq -er .privateKeyPath "$APPLE_DISTRIBUTION_KIT_CONFIG")"
provider_id="$(jq -er .team.providerPublicId "$MANIFEST")"
version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)"
[[ -n "$version" ]] || fail "could not read MARKETING_VERSION from project.yml"

# 1. The app, and the next build number.
asc_get --path /v1/apps --query "filter[bundleId]=$BUNDLE_ID" --query limit=1 > "$out/asc-app.json"
app_id="$(jq -r '.result.data[0].id // empty' "$out/asc-app.json")"
[[ -n "$app_id" ]] || fail "no App Store Connect app for $BUNDLE_ID"
asc_get --path /v1/builds --query "filter[app]=$app_id" --query 'sort=-uploadedDate' --query limit=200 > "$out/asc-builds-before.json"
if [[ -n "${GATEFOLD_BUILD_NUMBER:-}" ]]; then
  [[ "$GATEFOLD_BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "GATEFOLD_BUILD_NUMBER must be a number"
  build="$GATEFOLD_BUILD_NUMBER"
else
  build="$(jq -r --argjson floor "$BUILD_FLOOR" '[.result.data[]?.attributes.version | select(test("^[0-9]+$")) | tonumber] + [$floor] | max + 1' "$out/asc-builds-before.json")"
fi
[[ "$build" =~ ^[0-9]+$ ]] || fail "resolved build number is not a number"
echo "build=$build" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Publishing Gatefold $version ($build) from $(git rev-parse --short HEAD)"

# 2. Archive and export, signed manually with the imported identity.
xcodegen generate
xcodebuild archive -project Gatefold.xcodeproj -scheme Gatefold -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Gatefold.xcarchive" \
  -xcconfig "$GATEFOLD_SIGNING_XCCONFIG" CURRENT_PROJECT_VERSION="$build" > "$out/archive.log" 2>&1 \
  || { tail -80 "$out/archive.log"; fail "archive failed"; }
xcodebuild -exportArchive -archivePath "$out/Gatefold.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$GATEFOLD_EXPORT_OPTIONS_PLIST" > "$out/export.log" 2>&1 \
  || { tail -80 "$out/export.log"; fail "export failed"; }
ipa="$out/export/Gatefold.ipa"
[[ -f "$ipa" ]] || fail "no IPA at $ipa"
ipa_build="$(unzip -p "$ipa" 'Payload/*.app/Info.plist' | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || true)"
[[ "$ipa_build" == "$build" ]] || fail "the IPA is build ${ipa_build:-unknown}, expected $build"
shasum -a 256 "$ipa" | tee "$out/Gatefold.ipa.sha256"

# 3. Upload. A non-zero exit from altool is a failed upload, except in two cases where the build did reach App
# Store Connect; both go on to step 4, which judges the build by its processing state (gatefold#337).
#  - Delivered, then non-zero: in run 43318514534 App Store Connect answered three 500s, altool still logged
#    "UPLOAD SUCCEEDED" with a delivery UUID, waited an hour on processing (the kit passes --wait) and exited 1.
#  - A rerun of that run: App Store Connect refuses the same build number as a duplicate
#    (ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE, previousBundleVersion = this build). That counts only when App Store
#    Connect lists a build with this number and version, uploaded while this step ran in an earlier attempt of this
#    run (GitHub's jobs API, with GATEFOLD_GITHUB_TOKEN). Publishing is serialized, so no other run uploads then, and
#    a rerun publishes the same commit. A build uploaded at any other time is another run's, and the upload fails.
upload_ok=true
poll_checks=120
kit xcode run --kind altool-upload --mode apply --package-path "$ipa" --platform ios \
  --api-key "$key_id" --api-issuer "$issuer_id" --p8-file-path "$key_path" \
  --provider-public-id "$provider_id" --json > "$out/altool-upload.raw" || upload_ok=false
# Keep the key and issuer IDs, in the argv or in altool's own output, out of the log and the published artifact.
jq --arg k "$key_id" --arg i "$issuer_id" \
  'def scrub: reduce ([$k, $i][] | select(length > 0)) as $s (.; split($s) | join("[REDACTED]"));
   del(.command, .argv, .args) | if type == "object" then (.stdout, .stderr) |= (if type == "string" then scrub else . end) else . end' \
  "$out/altool-upload.raw" > "$out/altool-upload.json" 2>/dev/null \
  || { : > "$out/altool-upload.json"; [[ "$upload_ok" == false ]] || fail "the kit's upload answer is not JSON"; }
: > "$out/altool-upload.raw"
if [[ "$upload_ok" == false ]]; then
  cat "$out/altool-upload.json"
  upload_log="$(jq -r '[.stdout, .stderr] | map(strings) | join("\n")' "$out/altool-upload.json" 2>/dev/null || true)"
  delivery="$(sed -nE 's/^Delivery UUID: ([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})[[:space:]]*$/\1/p' <<< "$upload_log" | tail -1)"
  if grep -q '^UPLOAD SUCCEEDED' <<< "$upload_log" && ! grep -q 'UPLOAD FAILED' <<< "$upload_log" && [[ -n "$delivery" ]]; then
    printf '%s\n' "$delivery" > "$out/delivery-uuid.txt"
    echo "::warning title=altool exited non-zero after delivering::altool logged UPLOAD SUCCEEDED (delivery $delivery) but exited non-zero; App Store Connect's processing state decides (gatefold#337)."
    # altool has already waited on processing (up to an hour), so the poll gets 15 minutes, which keeps its own
    # verdict inside the job's 90-minute limit.
    poll_checks=30
  elif grep -q 'ENTITY_ERROR\.ATTRIBUTE\.INVALID\.DUPLICATE' <<< "$upload_log" \
    && grep -qE "previousBundleVersion\"?[[:space:]]*[:=][[:space:]]*\"?$build\"?([^0-9]|\$)" <<< "$upload_log"; then
    asc_get --path /v1/builds --query "filter[app]=$app_id" --query "filter[version]=$build" \
      --query "filter[preReleaseVersion.version]=$version" --query limit=5 > "$out/asc-build-existing.json" \
      || fail "upload failed: build $build is a duplicate, and App Store Connect could not be asked for it"
    listed="$(jq -r '.result.data | length' "$out/asc-build-existing.json")"
    if [[ "$listed" == 0 ]]; then
      fail "upload failed: App Store Connect already has an upload of build $build but lists no $version ($build); publish with a higher build_number"
    fi
    if ! uploaded_in_earlier_attempt "$(jq -r '.result.data[0].attributes.uploadedDate // empty' "$out/asc-build-existing.json")"; then
      fail "upload failed: App Store Connect already lists $version ($build), uploaded by another run; publish with a higher build_number"
    fi
    echo "::warning title=build $build was already uploaded::A previous attempt of this run uploaded $version ($build); App Store Connect's processing state decides (gatefold#337)."
  else
    fail "upload failed"
  fi
fi
date -u +%FT%TZ > "$out/uploaded-at.txt"

# 4. Wait for processing (up to an hour, or 15 minutes after altool's own wait).
build_id=""
for attempt in $(seq 1 "$poll_checks"); do
  asc_get --path /v1/builds --query "filter[app]=$app_id" --query "filter[version]=$build" \
    --query "filter[preReleaseVersion.version]=$version" --query limit=5 > "$out/asc-build-poll.json" || true
  state="$(jq -r '[.result.data[]?.attributes.processingState] | unique | join(",")' "$out/asc-build-poll.json" 2>/dev/null || true)"
  build_id="$(jq -r '.result.data[]? | select(.attributes.processingState == "VALID") | .id' "$out/asc-build-poll.json" 2>/dev/null | head -1)"
  [[ -n "$build_id" ]] && break
  [[ "$state" == *FAILED* || "$state" == *INVALID* ]] && fail "App Store Connect processing ended $state"
  echo "build $build not processed yet (state=${state:-not listed}, check $attempt/$poll_checks)"
  sleep 30
done
[[ -n "$build_id" ]] || fail "build $build was not processed within $((poll_checks / 2)) minutes of polling"
date -u +%FT%TZ > "$out/processed-at.txt"
echo "Build $build is processed ($build_id)"

# 5. Group, What's New, export compliance and the tester notification, through the kit.
asc_get --path "/v1/builds/$build_id/buildBetaDetail" > "$out/asc-build-beta-detail.json"
detail_id="$(jq -r '.result.data.id // empty' "$out/asc-build-beta-detail.json")"
[[ -n "$detail_id" ]] || fail "no build beta detail for $build_id"
asc_get --path "/v1/apps/$app_id/betaGroups" --query limit=200 > "$out/asc-beta-groups.json"
group_id="$(jq -r --arg name "$GROUP_NAME" '.result.data[]? | select(.attributes.name == $name) | .id' "$out/asc-beta-groups.json" | head -1)"
[[ -n "$group_id" ]] || fail "no TestFlight group named $GROUP_NAME"
notes="$(cat "$GATEFOLD_WHATS_NEW_FILE")"
jq --arg notes "$notes" '(.channels[] | select(.id == "ios-testflight") | .testflight.build.whatsNew) = $notes' \
  "$MANIFEST" > "$out/apple-distribution.release.json"
for mode in dry-run apply; do
  kit testflight publish --mode "$mode" --manifest "$out/apple-distribution.release.json" --channel ios-testflight \
    --app-id "$app_id" --build-id "$build_id" --build-beta-detail-id "$detail_id" \
    --group-id "$GROUP_NAME=$group_id" --artifact "$out/testflight-publish-$mode.json" \
    --config "$APPLE_DISTRIBUTION_KIT_CONFIG" --json > "$out/testflight-publish-$mode-output.json" \
    || { cat "$out/testflight-publish-$mode-output.json"; fail "testflight publish $mode failed"; }
done

# 6. Read back: the group lists the build, it is in beta testing, the notes are ours, and the
# tester is in the group.
in_group="false"
for _ in $(seq 1 20); do
  asc_get --path "/v1/betaGroups/$group_id/builds" --query limit=200 > "$out/asc-group-builds.json"
  in_group="$(jq -r --arg id "$build_id" 'any(.result.data[]?; .id == $id)' "$out/asc-group-builds.json")"
  [[ "$in_group" == "true" ]] && break
  sleep 15
done
[[ "$in_group" == "true" ]] || fail "$GROUP_NAME does not list build $build"
internal_state=""
for _ in $(seq 1 20); do
  asc_get --path "/v1/buildBetaDetails/$detail_id" > "$out/asc-build-beta-detail-after.json"
  internal_state="$(jq -r '.result.data.attributes.internalBuildState // empty' "$out/asc-build-beta-detail-after.json")"
  [[ "$internal_state" == "IN_BETA_TESTING" ]] && break
  sleep 15
done
[[ "$internal_state" == "IN_BETA_TESTING" ]] || fail "build $build is ${internal_state:-in no state}, not IN_BETA_TESTING"
asc_get --path "/v1/builds/$build_id/betaBuildLocalizations" > "$out/asc-notes.json"
jq -e --arg want "$notes" 'any(.result.data[]?; .attributes.locale == "en-US" and ((.attributes.whatsNew // "") | gsub("^\\s+|\\s+$"; "")) == ($want | gsub("^\\s+|\\s+$"; "")))' \
  "$out/asc-notes.json" > /dev/null || fail "What's New on build $build does not match"
if [[ -n "${GATEFOLD_TESTFLIGHT_TESTER:-}" ]]; then
  asc_get --path /v1/betaTesters --query "filter[email]=$GATEFOLD_TESTFLIGHT_TESTER" --query "filter[betaGroups]=$group_id" \
    --query 'fields[betaTesters]=state' | jq '{testersMatched: (.result.data | length)}' > "$out/tester-check.json"
  [[ "$(jq -r .testersMatched "$out/tester-check.json")" != "0" ]] || fail "the tester is not in $GROUP_NAME"
  testers=1
else
  # Only the count is kept: the answer holds testers' names and emails, and artifacts are public.
  testers="$(asc_get --path "/v1/betaGroups/$group_id/betaTesters" --query limit=200 | jq -r '.result.data | length')"
  (( testers > 0 )) || fail "$GROUP_NAME has no testers"
fi

jq -n --arg sourceSha "$(git rev-parse HEAD)" --arg version "$version" --arg buildNumber "$build" \
  --arg buildId "$build_id" --arg groupName "$GROUP_NAME" --arg groupId "$group_id" \
  --arg internalBuildState "$internal_state" --arg uploadedAt "$(cat "$out/uploaded-at.txt")" \
  --arg processedAt "$(cat "$out/processed-at.txt")" --arg availableAt "$(date -u +%FT%TZ)" \
  --argjson testerCheck "$testers" \
  '{sourceSha:$sourceSha, version:$version, buildNumber:$buildNumber, buildId:$buildId, groupName:$groupName,
    groupId:$groupId, internalBuildState:$internalBuildState, uploadedAt:$uploadedAt, processedAt:$processedAt,
    availableAt:$availableAt, testersChecked:$testerCheck}' | tee "$out/testflight-publish-summary.json"
echo "Gatefold $version ($build) is in $GROUP_NAME with its notes, in beta testing."
