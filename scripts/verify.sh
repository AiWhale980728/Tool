#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
developer_root="$(xcode-select -p)"
clt_root="/Library/Developer/CommandLineTools"
manifest_sdk="$clt_root/SDKs/MacOSX15.4.sdk"
target_sdk="$clt_root/SDKs/MacOSX26.5.sdk"
frameworks="$clt_root/Library/Developer/Frameworks"
testing_interop="$clt_root/Library/Developer/usr/lib"
scratch="$project_root/.build/verified"

cd "$project_root"

"$project_root/scripts/audit-origin.sh"

if [[ "$developer_root" == "$clt_root" && -d "$manifest_sdk" && -d "$target_sdk" ]]; then
    env \
        SDKROOT="$manifest_sdk" \
        CLANG_MODULE_CACHE_PATH="$scratch/module-cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache" \
        swift test \
        --disable-sandbox \
        --scratch-path "$scratch" \
        --cache-path "$scratch/cache" \
        --sdk "$target_sdk" \
        --triple arm64-apple-macosx14.0 \
        -Xswiftc -interface-compiler-version \
        -Xswiftc 6.3.2 \
        -Xswiftc -F \
        -Xswiftc "$frameworks" \
        -Xlinker -F \
        -Xlinker "$frameworks" \
        -Xlinker -rpath \
        -Xlinker "$frameworks" \
        -Xlinker -rpath \
        -Xlinker "$testing_interop"
else
    swift test
fi
