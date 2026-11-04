#!/bin/zsh
# Builds dist/Jarvis.app. A stable signing identity keeps macOS permissions across rebuilds;
# with ad-hoc signing you would have to grant them again after every build.
# Override the identity with: SIGN_IDENTITY="Apple Development: ..." scripts/build-app.sh
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

app=dist/Jarvis.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Jarvis" "$app/Contents/MacOS/Jarvis"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | tail -1)}"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app (signed with: ${identity:-ad-hoc})"
