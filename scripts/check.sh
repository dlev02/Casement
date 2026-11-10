#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# CI runners have no signing identity for the team, so builds there go unsigned, into their own
# folder: an unsigned Casement Host in .deriveddata would ask for the Keychain when a test starts it.
sign=()
dd=.deriveddata
[[ -n ${CI:-} ]] && sign=(CODE_SIGNING_ALLOWED=NO) && dd=.deriveddata-unsigned
scripts/lint.sh
xcrun swift test --package-path Packages/VantageCore
xcrun swift test
xcodebuild build -project Vantage.xcodeproj -scheme VantageHost -destination 'platform=macOS' -derivedDataPath "$dd" "${sign[@]}"
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" "${sign[@]}"
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'platform=macOS' -derivedDataPath "$dd" "${sign[@]}"
# Compiles the Mac UI tests; running them needs Automation Mode (see docs/guide/mac-client.md).
xcodebuild build-for-testing -project Vantage.xcodeproj -scheme VantageMacUITests -destination 'platform=macOS' -derivedDataPath "$dd" "${sign[@]}"
