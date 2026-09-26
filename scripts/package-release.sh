#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

RELEASE_APP="$PWD/dist/English Correct.app"
RELEASE_BINARY="$RELEASE_APP/Contents/MacOS/EnglishCorrect"
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist")"
RELEASE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RELEASE_APP/Contents/Info.plist")"
RELEASE_MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$RELEASE_APP/Contents/Info.plist")"
RELEASE_ARCH="$(xcrun lipo -archs "$RELEASE_BINARY")"

case "$RELEASE_VERSION" in
    ""|*[!A-Za-z0-9._-]*) echo "Invalid release version." >&2; exit 1 ;;
esac
if [ "$RELEASE_ARCH" != "arm64" ]; then
    echo "This package targets Apple silicon; found: $RELEASE_ARCH" >&2
    exit 1
fi

codesign --verify --strict "$RELEASE_APP"

# This app needs only the macOS frameworks and Swift runtime. Fail packaging if
# a later build accidentally links a local development library or search path.
while IFS= read -r dependency; do
    case "$dependency" in
        /System/Library/*|/usr/lib/*) ;;
        *) echo "Unexpected runtime dependency: $dependency" >&2; exit 1 ;;
    esac
done < <(otool -L "$RELEASE_BINARY" | awk 'NR > 1 { print $1 }')
while IFS= read -r runtime_path; do
    case "$runtime_path" in
        /usr/lib/swift|@loader_path) ;;
        *) echo "Unexpected runtime search path: $runtime_path" >&2; exit 1 ;;
    esac
done < <(otool -l "$RELEASE_BINARY" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')

SIGNATURE_DETAILS="$(codesign -d --verbose=2 "$RELEASE_APP" 2>&1)"
case "$SIGNATURE_DETAILS" in
    *"Authority=Developer ID Application:"*) SIGNING_NOTE="Signed with a Developer ID Application certificate." ;;
    *"Authority=Apple Development:"*) SIGNING_NOTE="Signed with an Apple Development certificate. This is a development build." ;;
    *"Signature=adhoc"*) SIGNING_NOTE="Ad-hoc signed; this build does not have an Apple-issued developer certificate." ;;
    *) SIGNING_NOTE="The app has a valid code signature; its signing identity is not a Developer ID Application certificate." ;;
esac
if xcrun stapler validate "$RELEASE_APP" >/dev/null 2>&1; then
    NOTARIZATION_NOTE="An Apple notarization ticket is attached to this app."
else
    NOTARIZATION_NOTE="No Apple notarization ticket is attached to this app. This packaging script does not submit the app for notarization."
fi

RELEASE_DIRECTORY="$PWD/dist/releases"
mkdir -p "$RELEASE_DIRECTORY"
PACKAGE_WORK="$(mktemp -d "$PWD/dist/.package-release.XXXXXX")"
PACKAGE_STAGE="$PACKAGE_WORK/payload"
PACKAGE_MOUNT="$PACKAGE_WORK/mounted"
PACKAGE_IS_MOUNTED=0
cleanup() {
    if [ "$PACKAGE_IS_MOUNTED" -eq 1 ]; then
        if ! hdiutil detach "$PACKAGE_MOUNT" >/dev/null; then
            echo "Could not detach validation volume: $PACKAGE_MOUNT" >&2
            return
        fi
    fi
    rm -rf "$PACKAGE_WORK"
}
trap cleanup EXIT
mkdir -p "$PACKAGE_STAGE" "$PACKAGE_MOUNT"
ditto "$RELEASE_APP" "$PACKAGE_STAGE/English Correct.app"
ln -s /Applications "$PACKAGE_STAGE/Applications"

cat > "$PACKAGE_STAGE/INSTALL.txt" <<EOF
English Correct $RELEASE_VERSION (build $RELEASE_BUILD)

Requires an Apple silicon Mac (M1 or later) with macOS $RELEASE_MINIMUM_OS or later.

1. If updating, quit the existing English Correct app first. Drag
   English Correct.app to the Applications folder shown beside it.
2. Eject this disk image, then open English Correct from Applications.
3. Follow the Setup Guide. Install LM Studio 0.4 or newer separately and
   start its local server on port 1234. In Models, choose Download Fast or
   Download Pro, then Use Fast or Use Pro when the download finishes.
4. To check writing in other apps, grant Accessibility access and choose
   which apps you allow. Automatic suggestions require your explicit choice.

Model weights and AI runtimes are not included in this download.

$SIGNING_NOTE
$NOTARIZATION_NOTE
macOS Gatekeeper may block opening this build. Review Apple's guidance:
https://support.apple.com/en-us/102445
Only proceed if you trust the source. Keep macOS security protections enabled.
EOF

# Package a deliberate allowlist, not everything left in the build directory.
while IFS= read -r resource; do
    case "${resource#"$PACKAGE_STAGE/English Correct.app/"}" in
        Contents/Info.plist|Contents/MacOS/EnglishCorrect|Contents/Resources/AppIcon.icns|Contents/_CodeSignature/CodeResources) ;;
        Contents/Resources/Credits/Attribution.txt|Contents/Resources/Credits/Sources.json) ;;
        Contents/Resources/Credits/Qwen2.5-1.5B-Instruct-LICENSE.txt|Contents/Resources/Credits/Qwen2.5-7B-Instruct-LICENSE.txt) ;;
        *) echo "Unexpected app resource; review before distribution: $resource" >&2; exit 1 ;;
    esac
done < <(find "$PACKAGE_STAGE/English Correct.app" -type f)
if [ -n "$(find "$PACKAGE_STAGE/English Correct.app" -type l -print -quit)" ]; then
    echo "Unexpected symlink inside the app bundle." >&2
    exit 1
fi
codesign --verify --strict "$PACKAGE_STAGE/English Correct.app"

PACKAGE_NAME="English-Correct-$RELEASE_VERSION-$RELEASE_ARCH.dmg"
PACKAGE_PATH="$RELEASE_DIRECTORY/$PACKAGE_NAME"
hdiutil create -volname "English Correct $RELEASE_VERSION" -fs HFS+ -srcfolder "$PACKAGE_STAGE" -format UDZO -ov "$PACKAGE_PATH"
hdiutil verify "$PACKAGE_PATH"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$PACKAGE_MOUNT" "$PACKAGE_PATH" >/dev/null
PACKAGE_IS_MOUNTED=1
codesign --verify --strict "$PACKAGE_MOUNT/English Correct.app"
cmp "$RELEASE_BINARY" "$PACKAGE_MOUNT/English Correct.app/Contents/MacOS/EnglishCorrect"
test "$(readlink "$PACKAGE_MOUNT/Applications")" = "/Applications"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PACKAGE_MOUNT/English Correct.app/Contents/Info.plist")" = "$RELEASE_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PACKAGE_MOUNT/English Correct.app/Contents/Info.plist")" = "$RELEASE_BUILD"
test "$(xcrun lipo -archs "$PACKAGE_MOUNT/English Correct.app/Contents/MacOS/EnglishCorrect")" = "$RELEASE_ARCH"
cmp "$PACKAGE_STAGE/INSTALL.txt" "$PACKAGE_MOUNT/INSTALL.txt"
hdiutil detach "$PACKAGE_MOUNT" >/dev/null
PACKAGE_IS_MOUNTED=0

(
    cd "$RELEASE_DIRECTORY"
    shasum -a 256 "$PACKAGE_NAME" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
echo "Packaged: $PACKAGE_PATH ($(stat -f '%z' "$PACKAGE_PATH") bytes)"
echo "$SIGNING_NOTE"
echo "$NOTARIZATION_NOTE"
