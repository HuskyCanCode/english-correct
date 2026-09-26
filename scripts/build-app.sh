#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Rely on the Swift runtime shipped with macOS, not this Mac's Xcode path.
swift build -c release -Xswiftc -no-toolchain-stdlib-rpath
APP="$PWD/dist/English Correct.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EnglishCorrect "$APP/Contents/MacOS/EnglishCorrect"
# SwiftPM may explicitly add its toolchain search path despite the driver flag.
# Remove that unused development path from the copy before final signing.
while IFS= read -r runtime_path; do
    case "$runtime_path" in
        */Toolchains/*.xctoolchain/usr/lib/swift*)
            xcrun install_name_tool -delete_rpath "$runtime_path" "$APP/Contents/MacOS/EnglishCorrect"
            ;;
    esac
done < <(otool -l "$APP/Contents/MacOS/EnglishCorrect" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
cp Resources/Info.plist "$APP/Contents/Info.plist"
test -s Sources/EnglishCorrect/Resources/Credits/Qwen2.5-1.5B-Instruct-LICENSE.txt
test -s Sources/EnglishCorrect/Resources/Credits/Qwen2.5-7B-Instruct-LICENSE.txt
ditto Sources/EnglishCorrect/Resources/Credits "$APP/Contents/Resources/Credits"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
# A certificate-backed identity lets macOS recognize later local builds as the
# same app. Explicit overrides win; ambiguous keychains keep the ad-hoc default.
SIGNING_IDENTITY="${ENGLISH_CORRECT_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning | awk '/"(Apple Development:|Developer ID Application:)/ { print $2 }')"
    IDENTITY_COUNT="$(printf '%s\n' "$IDENTITIES" | awk 'NF { count++ } END { print count+0 }')"
    if [ "$IDENTITY_COUNT" -eq 1 ]; then
        SIGNING_IDENTITY="$IDENTITIES"
        echo "Signing with the available certificate identity."
    else
        SIGNING_IDENTITY="-"
        echo "Using ad-hoc signing ($IDENTITY_COUNT eligible identities); set ENGLISH_CORRECT_SIGNING_IDENTITY to choose one."
    fi
fi
python3 scripts/prepare-local-engine.py "$APP/Contents/Resources/LocalEngine"
for engine_file in "$APP/Contents/Resources/LocalEngine/"*; do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$engine_file"
done
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.englishcorrect.app --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
