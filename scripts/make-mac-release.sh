#!/bin/zsh
# Builds Casement Host for Mac for a GitHub release: a Developer ID signed, notarized and stapled
# DMG and zip, a signed Sparkle appcast.xml pointing at the release's tag, and SHA-256 checksums,
# in build/mac-release/<version>. It uploads nothing.
#
#   scripts/make-mac-release.sh 1.4
#   scripts/make-mac-release.sh --throwaway 0.0.1   a test run: any version, tracked changes allowed
#
# Set the version in the pbxproj first (its own commit). Needs, on this Mac:
#   - The Developer ID Application certificate for team 7BVMD7TA97, in the login Keychain.
#   - Notarization credentials: an App Store Connect API key, the way earlier releases were done, in
#     ASC_PRIVATE_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (or NOTARY_KEY_PATH, NOTARY_KEY_ID and
#     NOTARY_ISSUER_ID), or a keychain profile from `xcrun notarytool store-credentials` in NOTARY_PROFILE.
#   - The Sparkle private key, in the login Keychain (Sparkle's generate_keys made it), or in the
#     file named by CASEMENT_ED_KEY_FILE. macOS may ask once to let generate_appcast read it. Choose
#     Always Allow. Lose this key and every installed copy needs a download by hand.
set -euo pipefail

cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

die() { print -u2 "make-mac-release: $*"; exit 1; }
step() { print "\n== $*"; }

throwaway=0
if [[ "${1:-}" == "--throwaway" ]]; then throwaway=1; shift; fi
version="${1:-}"
[[ "$version" =~ '^[0-9]+(\.[0-9]+)+$' ]] || die "usage: make-mac-release.sh [--throwaway] <version>, for example 1.4"

team=7BVMD7TA97
tag="host-$version"
repo=https://github.com/dlev02/Casement
out="build/mac-release/$version"
derived=.deriveddata
sparkle_bin="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
dmg="Casement-Host-$version-mac.dmg"
zip="Casement-Host-$version-mac.zip"

# Everything that needs setting up on this Mac fails here, not after a long build.
identity=$(security find-identity -v -p codesigning | awk -v team="($team)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
[[ -n "$identity" ]] || die "no Developer ID Application certificate for team $team in the Keychain"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$NOTARY_PROFILE")
else
  key_path="${NOTARY_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
  key_id="${NOTARY_KEY_ID:-${ASC_KEY_ID:-}}"
  issuer="${NOTARY_ISSUER_ID:-${ASC_ISSUER_ID:-}}"
  [[ -n "$key_path" && -n "$key_id" && -n "$issuer" ]] \
    || die "no notarization credentials: set ASC_PRIVATE_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or NOTARY_PROFILE"
  notary=(--key "$key_path" --key-id "$key_id" --issuer "$issuer")
fi
xcrun notarytool history "${notary[@]}" >/dev/null || die "Apple refused those notarization credentials"

overrides=()
if (( throwaway )); then
  overrides=("MARKETING_VERSION=$version")
else
  git diff --quiet HEAD -- || die "tracked files have changes: commit first, so the release is what's in the repository"
  set_version=$(xcodebuild -showBuildSettings -project Vantage.xcodeproj -scheme VantageHost -configuration Release 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
  [[ "$set_version" == "$version" ]] || die "the project says $set_version, not $version: set MARKETING_VERSION first"
fi

rm -rf "$out"
mkdir -p "$out"

step "Archiving"
xcodebuild archive -project Vantage.xcodeproj -scheme VantageHost -configuration Release \
  -destination generic/platform=macOS -derivedDataPath "$derived" -archivePath "$out/Host.xcarchive" \
  "${overrides[@]}" > "$out/archive.log" 2>&1 || { tail -30 "$out/archive.log"; die "the archive failed; see $out/archive.log"; }

step "Signing with Developer ID"
# The export signs nested code from the inside out, Sparkle's helpers included.
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>teamID</key><string>$team</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/Host.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" > "$out/export.log" 2>&1 \
  || { tail -30 "$out/export.log"; die "the export failed; see $out/export.log"; }
app="$out/export/Casement Host.app"

codesign --verify --deep --strict "$app" || die "the app's signature doesn't verify"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for code in "$app" "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
  details=$(codesign -dvv "$code" 2>&1)
  [[ "$details" == *"Authority=Developer ID Application"* && "$details" == *"TeamIdentifier=$team"* ]] \
    || die "$code isn't signed with team $team's Developer ID"
  [[ "$details" == *"runtime"* ]] || codesign -d --verbose=4 "$code" 2>&1 | grep -q runtime || die "$code has no hardened runtime"
done
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q get-task-allow; then
  die "the app still has get-task-allow, which notarization refuses"
fi
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]] || die "the app isn't version $version"

notarize() {
  local result="$out/notary-${1:t}.json"
  xcrun notarytool submit "$1" "${notary[@]}" --wait --output-format json > "$result" || true
  local verdict; verdict=$(/usr/bin/plutil -extract status raw "$result" 2>/dev/null || print unknown)
  if [[ "$verdict" != "Accepted" ]]; then
    local id; id=$(/usr/bin/plutil -extract id raw "$result" 2>/dev/null || print "")
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary[@]}" || true
    die "notarizing ${1:t} came back $verdict"
  fi
}

step "Notarizing the app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/notarize-app.zip"
notarize "$out/notarize-app.zip"
rm "$out/notarize-app.zip"
xcrun stapler staple -q "$app"
xcrun stapler validate -q "$app"
spctl --assess --type execute "$app" || die "Gatekeeper refuses the stapled app"

step "Making the zip"
# ditto keeps the framework's symlinks, which a plain zip would break.
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$zip"

step "Making and notarizing the DMG"
folder="$out/dmg"
mkdir "$folder"
ditto "$app" "$folder/Casement Host.app"
ln -s /Applications "$folder/Applications"
hdiutil create -quiet -volname "Casement Host" -srcfolder "$folder" -ov -format UDZO "$out/$dmg"
rm -rf "$folder"
codesign --sign "$identity" --timestamp "$out/$dmg"
notarize "$out/$dmg"
xcrun stapler staple -q "$out/$dmg"
xcrun stapler validate -q "$out/$dmg"

step "Signing the appcast"
# Only the zip goes in: Sparkle installs from it, and the DMG is for people.
stage="$out/appcast-stage"
mkdir "$stage"
ln "$out/$zip" "$stage/$zip"
key=()
[[ -n "${CASEMENT_ED_KEY_FILE:-}" ]] && key=(--ed-key-file "$CASEMENT_ED_KEY_FILE")
"$sparkle_bin/generate_appcast" "${key[@]}" --maximum-deltas 0 \
  --download-url-prefix "$repo/releases/download/$tag/" --link "$repo/releases/tag/$tag" \
  -o "$out/appcast.xml" "$stage" | tee "$out/appcast.log"
rm -rf "$stage"
xmllint --noout "$out/appcast.xml"
grep -q "url=\"$repo/releases/download/$tag/$zip\"" "$out/appcast.xml" || die "the appcast's enclosure doesn't point at $tag"
grep -q 'sparkle:edSignature=' "$out/appcast.xml" || die "the download isn't signed in the appcast"
grep -q 'sparkle-signatures:' "$out/appcast.xml" || die "the appcast itself isn't signed, and the app requires that"
grep -qi 'warning' "$out/appcast.log" && die "generate_appcast warned; see $out/appcast.log"

step "Checksums"
(cd "$out" && shasum -a 256 "$dmg" "$zip" appcast.xml > "Casement-Host-$version-mac.sha256" && cat "Casement-Host-$version-mac.sha256")

print "\nReady in $out. Nothing has been uploaded. To publish, attach these to the release tagged $tag:"
print "  $dmg  $zip  appcast.xml  Casement-Host-$version-mac.sha256"
print "Installed copies see it once that release is the latest: a draft or prerelease is invisible to them."
