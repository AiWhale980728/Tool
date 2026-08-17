#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/.build/verified/arm64-apple-macosx/debug"
app_parent="$project_root/.build/local-app"
app_bundle="$app_parent/Notch Relay.app"
expected_bundle="$project_root/.build/local-app/Notch Relay.app"

if [[ "${1:-}" != "--skip-verify" ]]; then
    "$project_root/scripts/verify.sh"
fi

if [[ ! -x "$build_root/NotchRelayApp" ]]; then
    print -u2 "NotchRelayApp has not been built"
    exit 1
fi

if [[ "$app_bundle" != "$expected_bundle" ]]; then
    print -u2 "refusing to replace an unexpected app path"
    exit 1
fi

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$build_root/NotchRelayApp" "$app_bundle/Contents/MacOS/NotchRelayApp"
cp "$project_root/Packaging/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_root/LICENSE" "$app_bundle/Contents/Resources/LICENSE.txt"
cp "$project_root/THIRD_PARTY_NOTICES.md" "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
ditto \
    "$build_root/NotchRelay_NotchRelayApp.bundle" \
    "$app_bundle/Contents/Resources/NotchRelay_NotchRelayApp.bundle"
codesign --force --deep --sign - "$app_bundle"

print "$app_bundle"
