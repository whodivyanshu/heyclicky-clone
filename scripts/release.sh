#!/bin/zsh
# Builds a release others can install: signed with Developer ID, notarized and stapled, plus a signed update feed.
# It only writes to dist/release. Publishing the files is up to you.
#
# One-time setup:
#   1. A "Developer ID Application" certificate, from a paid Apple Developer account.
#   2. xcrun notarytool store-credentials jarvis-notary
#   3. swift build, then .build/artifacts/sparkle/Sparkle/bin/generate_keys
#      This keeps the private update key in your Keychain, and prints the public key for SU_PUBLIC_KEY.
#
# Each release:
#   VERSION=0.2.0 SU_FEED_URL=https://example.com/appcast.xml SU_PUBLIC_KEY=... scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."

: "${VERSION:?Set VERSION, such as 0.2.0}"
: "${SU_FEED_URL:?Set SU_FEED_URL to the https address where appcast.xml will be published}"
: "${SU_PUBLIC_KEY:?Set SU_PUBLIC_KEY to the public key from generate_keys}"
notary_profile="${NOTARY_PROFILE:-jarvis-notary}"

identity="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
if [[ "$identity" != Developer\ ID\ Application:* ]]; then
    echo "No Developer ID Application certificate found. Apple only notarizes apps signed with one." >&2
    exit 1
fi

scripts/build-app.sh
app=dist/Jarvis.app
out=dist/release
rm -rf "$out"
mkdir -p "$out"

plist="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
# Sparkle compares this number, so it has to go up with every release.
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$plist"
plutil -replace SUFeedURL -string "$SU_FEED_URL" "$plist"
plutil -replace SUPublicEDKey -string "$SU_PUBLIC_KEY" "$plist"
plutil -replace SUEnableAutomaticChecks -bool true "$plist"

# Signed from the inside out, in the order Sparkle's documentation gives.
sign=(codesign --force --timestamp --options runtime --sign "$identity")
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
"${sign[@]}" "$sparkle/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
"${sign[@]}" "$sparkle/Autoupdate"
"${sign[@]}" "$sparkle/Updater.app"
"${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" --entitlements Resources/Jarvis.entitlements "$app"
codesign --verify --deep --strict "$app"

archive="$out/Jarvis-$VERSION.zip"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute "$app"

# Zipped again so the download includes the stapled ticket.
rm "$archive"
ditto -c -k --keepParent "$app" "$archive"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "$out"

echo "Ready to publish from $out: upload $(basename "$archive") and appcast.xml to the address in SU_FEED_URL."
