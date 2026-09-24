#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swift test --package-path Packages/VantageCore
xcrun swift test
xcodebuild build -project Vantage.xcodeproj -scheme VantageHost -destination 'platform=macOS' -derivedDataPath .deriveddata
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'generic/platform=iOS Simulator' -derivedDataPath .deriveddata
xcodebuild build -project Vantage.xcodeproj -scheme Vantage -destination 'platform=macOS' -derivedDataPath .deriveddata
# Compiles the Mac UI tests; running them needs Automation Mode (see CLAUDE.md, macOS client).
xcodebuild build-for-testing -project Vantage.xcodeproj -scheme VantageMacUITests -destination 'platform=macOS' -derivedDataPath .deriveddata
