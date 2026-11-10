#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_directory="${MONOSPLIT_APP_DIR:-$PWD/build/MonoSplitFineTune.app}"
if pgrep -f "^$app_directory/Contents/MacOS/monosplit-gpui$" >/dev/null; then
    print -u2 "Quit MonoSplitFineTune before replacing its bundle, or set MONOSPLIT_APP_DIR to a staging path."
    exit 1
fi
scripts/build-gpui-host.sh
# Release builds compile the frontend from this checkout. Developers may opt
# into reusing it while iterating only on the Swift host.
frontend="$PWD/build/MonoSplitGPUI.app/Contents/MacOS/monosplit-gpui"
if [[ "${MONOSPLIT_REUSE_FRONTEND:-0}" != "1" || ! -f "$frontend" ]]; then
    cargo build --release --manifest-path gpui/Cargo.toml --locked
    frontend="$PWD/gpui/target/release/monosplit-gpui"
fi
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Frameworks" "$app_directory/Contents/Resources"
cp "$frontend" "$app_directory/Contents/MacOS/monosplit-gpui"
# Cargo test binaries use the local host-library search path; release bundles
# resolve it only from their own Frameworks directory.
install_name_tool -delete_rpath "$PWD/gpui/../build/gpui-native" "$app_directory/Contents/MacOS/monosplit-gpui"
cp build/gpui-native/libMonoSplitHost.dylib "$app_directory/Contents/Frameworks/"
cp Resources/AppIcon.icns "$app_directory/Contents/Resources/"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
cp LICENSE "$app_directory/Contents/Resources/"
if [[ -f THIRD_PARTY_NOTICES.md ]]; then cp THIRD_PARTY_NOTICES.md "$app_directory/Contents/Resources/"; fi
if [[ -d third-party-licenses ]]; then ditto third-party-licenses "$app_directory/Contents/Resources/third-party-licenses"; fi
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable monosplit-gpui' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.monosplit.gpui' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName MonoSplit GPUI' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.5.0' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 8' "$app_directory/Contents/Info.plist"
codesign --force --sign - "$app_directory/Contents/Frameworks/libMonoSplitHost.dylib"
codesign --force --sign - "$app_directory"
codesign --verify --strict "$app_directory"
print "$app_directory"
