#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scripts/build-gpui-host.sh
binary_directory="$(swift build -c release --triple "$(uname -m)-apple-macosx15.4" --show-bin-path)"
test_directory="$(mktemp -d /tmp/monosplit-bridge.XXXXXX)"
trap 'rm -rf "$test_directory"' EXIT
swiftc -O -swift-version 6 -target "$(uname -m)-apple-macosx15.4" \
    -I "$binary_directory/Modules" -I "$binary_directory/MonoSplitDSP.build" \
    Sources/MonoSplit/AppModel.swift Sources/MonoSplit/CoreAudioHost.swift Sources/MonoSplit/AudioPresentation.swift \
    gpui/native/HostBridge.swift Verification/GPUIBridgeChecks.swift \
    "$binary_directory"/MonoSplitCore.build/*.o "$binary_directory"/MonoSplitDSP.build/*.o \
    -lc++ -framework CoreAudio -framework AppKit -o "$test_directory/checks"
MONOSPLIT_TEST_MODE=1 MONOSPLIT_PROFILE_DIR="$test_directory/profiles" "$test_directory/checks"
