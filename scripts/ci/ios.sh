#!/usr/bin/env bash
# Runs on a real macOS/Xcode runner. No Apple credentials or signing are used.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  minimum) expected_sdk="26.0"; evidence="artifacts/ios-minimum" ;;
  test) expected_sdk="26.2"; evidence="artifacts/ios-tests" ;;
  *) echo 'Usage: bash scripts/ci/ios.sh minimum|test' >&2; exit 2 ;;
esac

mkdir -p "$evidence"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'iOS validation requires macOS/Xcode (use the GitHub Actions macOS job).' | tee "$evidence/preflight.log" >&2
  exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo 'Configured Xcode is unavailable. Check the runner image; do not silently use another SDK.' | tee "$evidence/preflight.log" >&2
  exit 2
fi

{
  sw_vers
  uname -m
  printf 'DEVELOPER_DIR=%s\nImageOS=%s\nImageVersion=%s\n' "$DEVELOPER_DIR" "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
  xcodebuild -version
  xcodebuild -showsdks
  xcrun swift --version
} 2>&1 | tee "$evidence/environment.log"

sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "$sdk_version" != "$expected_sdk" ]]; then
  printf 'Expected simulator SDK %s, found %s.\n' "$expected_sdk" "$sdk_version" | tee "$evidence/preflight.log" >&2
  exit 2
fi

derived_data="DerivedData/ci-$mode"
trap 'if [[ -f PairNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved ]]; then cp PairNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved "$evidence/Package.resolved"; fi' EXIT
common=(
  -project PairNotes.xcodeproj -scheme PairNotes -configuration Debug
  -sdk iphonesimulator -derivedDataPath "$derived_data"
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= APP_ENTITLEMENTS= WIDGET_ENTITLEMENTS=
  PAIRNOTES_APP_GROUP=
)

if [[ "$mode" == minimum ]]; then
  # build-for-testing checks the test target against SDK 26.0 as well.
  xcodebuild "${common[@]}" \
    -destination 'generic/platform=iOS Simulator' \
    -resultBundlePath "$evidence/Build.xcresult" \
    build-for-testing 2>&1 | tee "$evidence/xcodebuild.log"

  app="$derived_data/Build/Products/Debug-iphonesimulator/PairNotes.app"
  test -d "$app/PlugIns/PairNotesWidgets.appex"
  tar -czf "$evidence/PairNotes-simulator.tar.gz" -C "$(dirname "$app")" PairNotes.app
else
  xcrun simctl list devices available --json > "$evidence/devices.json"
  xcrun simctl list runtimes --json > "$evidence/runtimes.json"
  simulator_id="$(python3 scripts/ci/select_simulator.py "$evidence/devices.json" --runtime 26.2)"
  printf '%s\n' "$simulator_id" > "$evidence/simulator-id.txt"
  # bootstatus -b boots if needed and waits; xcodebuild also checks destination readiness.
  xcrun simctl bootstatus "$simulator_id" -b 2>&1 | tee "$evidence/boot.log"
  test_status=0
  xcodebuild "${common[@]}" \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -destination-timeout 180 -parallel-testing-enabled NO \
    -only-testing:PairNotesNativeTests/NativeEditorPersistenceTests/testVisiblePaperColorAndLayerFramesSurviveLayoutPaletteAndAppearanceChanges \
    -only-testing:PairNotesNativeTests/NativeEditorPersistenceTests/testLetterComposerLayoutInLightAndDarkAppearance \
    -only-testing:PairNotesUITests/EditorInteractionTests/testFingerDrawingSurvivesModesPhotoCancellationAndSaveReopen \
    -resultBundlePath "$evidence/Tests.xcresult" \
    test 2>&1 | tee "$evidence/xcodebuild.log" || test_status=$?

  # The bundle remains the authoritative result; these are Linux-readable evidence.
  evidence_status=0
  if [[ -d "$evidence/Tests.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$evidence/Tests.xcresult" \
      --output-path "$evidence/attachments" || evidence_status=$?
    xcrun xcresulttool get test-results summary --path "$evidence/Tests.xcresult" \
      > "$evidence/test-summary.json" || evidence_status=$?
  fi
  if [[ "$test_status" != 0 ]]; then exit "$test_status"; fi
  exit "$evidence_status"
fi
