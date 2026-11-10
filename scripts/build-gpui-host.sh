#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --triple "$(uname -m)-apple-macosx15.4" --target MonoSplitCore
binary_directory="$(swift build -c release --triple "$(uname -m)-apple-macosx15.4" --show-bin-path)"
mkdir -p build/gpui-native
swiftc -emit-library -O -swift-version 6 -target "$(uname -m)-apple-macosx15.4" \
  -module-name MonoSplitHost \
  -I "$binary_directory/Modules" -I "$binary_directory/MonoSplitDSP.build" \
  Sources/MonoSplit/AppModel.swift Sources/MonoSplit/CoreAudioHost.swift Sources/MonoSplit/AudioPresentation.swift gpui/native/HostBridge.swift \
  "$binary_directory"/MonoSplitCore.build/*.o "$binary_directory"/MonoSplitDSP.build/*.o \
  -lc++ -framework CoreAudio -framework AppKit \
  -Xlinker -install_name -Xlinker '@rpath/libMonoSplitHost.dylib' \
  -o build/gpui-native/libMonoSplitHost.dylib
