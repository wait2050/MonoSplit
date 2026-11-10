#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_directory="$(mktemp -d /tmp/monosplit-pcm.XXXXXX)"
trap 'rm -rf "$test_directory"' EXIT
clang -std=c11 -O1 -g -fsanitize=address,undefined \
    -I Sources/MonoSplitDSP/include Integration/PCMBridgeTests.c \
    Sources/MonoSplitDSP/MonoSplitPCM.c -o "$test_directory/checks"
"$test_directory/checks"
if [[ -f ../FineTune/FineTune/Audio/MonoSplit/MonoSplitPCM.c ]]; then
    cmp Sources/MonoSplitDSP/MonoSplitPCM.c ../FineTune/FineTune/Audio/MonoSplit/MonoSplitPCM.c
    cmp Sources/MonoSplitDSP/include/MonoSplitPCM.h ../FineTune/FineTune/Audio/MonoSplit/MonoSplitPCM.h
fi
