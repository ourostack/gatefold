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
# the key file by path, and xcodebuild signs with the imported identity without Apple's servers.
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
asc_get() { kit asc get "$@" --config "$APPLE_DISTRIBUTION_KIT_CONFIG" --json; }

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

# 3. Upload.
kit xcode run --kind altool-upload --mode apply --package-path "$ipa" --platform ios \
  --api-key "$key_id" --api-issuer "$issuer_id" --p8-file-path "$key_path" \
  --provider-public-id "$provider_id" --json > "$out/altool-upload.json" \
  || { cat "$out/altool-upload.json"; fail "upload failed"; }
date -u +%FT%TZ > "$out/uploaded-at.txt"

# 4. Wait for processing (up to an hour).
build_id=""
for attempt in $(seq 1 120); do
  asc_get --path /v1/builds --query "filter[app]=$app_id" --query "filter[version]=$build" \
    --query "filter[preReleaseVersion.version]=$version" --query limit=5 > "$out/asc-build-poll.json" || true
  state="$(jq -r '[.result.data[]?.attributes.processingState] | unique | join(",")' "$out/asc-build-poll.json" 2>/dev/null || true)"
  build_id="$(jq -r '.result.data[]? | select(.attributes.processingState == "VALID") | .id' "$out/asc-build-poll.json" 2>/dev/null | head -1)"
  [[ -n "$build_id" ]] && break
  [[ "$state" == *FAILED* || "$state" == *INVALID* ]] && fail "App Store Connect processing ended $state"
  echo "build $build not processed yet (state=${state:-not listed}, check $attempt/120)"
  sleep 30
done
[[ -n "$build_id" ]] || fail "build $build was not processed within an hour"
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
    --query 'fields[betaTesters]=state' > "$out/asc-tester.json"
  [[ "$(jq -r '.result.data | length' "$out/asc-tester.json")" != "0" ]] || fail "the tester is not in $GROUP_NAME"
  testers=1
else
  asc_get --path "/v1/betaGroups/$group_id/betaTesters" --query limit=200 > "$out/asc-group-testers.json"
  testers="$(jq -r '.result.data | length' "$out/asc-group-testers.json")"
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
