#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
scripts/build-gpui-host.sh
if [[ "$configuration" == "release" ]]; then
    cargo build --release --manifest-path gpui/Cargo.toml --locked
else
    cargo build --manifest-path gpui/Cargo.toml --locked
    configuration="debug"
fi
app_directory="$PWD/build/MonoSplitGPUI.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" "$app_directory/Contents/Frameworks"
cp "gpui/target/$configuration/monosplit-gpui" "$app_directory/Contents/MacOS/monosplit-gpui"
cp build/gpui-native/libMonoSplitHost.dylib "$app_directory/Contents/Frameworks/"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable monosplit-gpui' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.monosplit.gpui' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName MonoSplit GPUI' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.4.1' "$app_directory/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 7' "$app_directory/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/build"
iconutil -c icns build/AppIcon.iconset -o "$app_directory/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_directory/Contents/Frameworks/libMonoSplitHost.dylib"
codesign --force --sign - "$app_directory"
codesign --verify --strict "$app_directory"
printf '\n%s\n' "$app_directory"
