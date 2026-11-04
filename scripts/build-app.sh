#!/bin/zsh
# Builds dist/Jarvis.app. A stable signing identity keeps macOS permissions across rebuilds;
# with ad-hoc signing you would have to grant them again after every build.
# Override the identity with: SIGN_IDENTITY="Apple Development: ..." scripts/build-app.sh
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

app=dist/Jarvis.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
bin_path="$(swift build -c release --show-bin-path)"
cp "$bin_path/Jarvis" "$app/Contents/MacOS/Jarvis"
ditto "$bin_path/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"

# What lets Shortcuts and Siri find the "Ask Jarvis" action. Xcode makes this by itself, but swift build doesn't.
scratch="$(mktemp -d)"
find .build/out/Intermediates.noindex/Jarvis.build/Release/Jarvis-p.build -name '*.swiftconstvalues' > "$scratch/values.txt"
print -l "$PWD"/Sources/Jarvis/*.swift > "$scratch/sources.txt"
xcrun appintentsmetadataprocessor --quiet-warnings \
    --output "$app/Contents/Resources" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name Jarvis \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
    --source-file-list "$scratch/sources.txt" --swift-const-vals-list "$scratch/values.txt" \
    --binary-file "$bin_path/Jarvis" >/dev/null 2>&1 \
    || echo "warning: couldn't build the Shortcuts metadata, so Ask Jarvis won't appear in Shortcuts." >&2
rm -rf "$scratch"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | tail -1)}"
codesign --force --sign "${identity:--}" "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app (signed with: ${identity:-ad-hoc})"
