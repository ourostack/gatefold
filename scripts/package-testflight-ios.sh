#!/usr/bin/env bash
# Archives and exports Gatefold for TestFlight. Signing is automatic with team 743GT2AJ24;
# pass App Store Connect API key auth through the environment when running unattended:
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
set -euo pipefail
cd "$(dirname "$0")/.."
out="${GATEFOLD_ARCHIVE_DIR:-build}"
mkdir -p "$out"
auth=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodegen generate
xcodebuild archive -project Gatefold.xcodeproj -scheme Gatefold -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Gatefold.xcarchive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
xcodebuild -exportArchive -archivePath "$out/Gatefold.xcarchive" \
  -exportOptionsPlist distribution/ExportOptions.testflight.plist -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
echo "$out/export/Gatefold.ipa"
