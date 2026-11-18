#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
work="$root/.build/app"
output="$root/dist"
app="$output/Switch Captures.app"
developer_dir="$(xcode-select -p)"

if [[ -n "${SWITCH_CAPTURES_SDK:-}" ]]; then
    sdk="$SWITCH_CAPTURES_SDK"
elif [[ -d "$developer_dir/SDKs/MacOSX.sdk" ]]; then
    sdk="$developer_dir/SDKs/MacOSX.sdk"
else
    sdk="$(xcrun --show-sdk-path)"
fi

build_arch() {
    local arch="$1"
    local arch_dir="$work/$arch"
    local target="$arch-apple-macosx14.0"
    mkdir -p "$arch_dir"
    local swift_flags=(-sdk "$sdk" -module-cache-path "$arch_dir/cache" -swift-version 6 -target "$target"
        -O -whole-module-optimization -I "$root/Sources/SwitchUSB/include")

    xcrun clang -target "$target" -isysroot "$sdk" -O2 -I Sources/SwitchUSB/include \
        -c Sources/SwitchUSB/SwitchUSB.c -o "$arch_dir/SwitchUSB.o"
    xcrun swiftc "${swift_flags[@]}" -module-name CaptureTransfer -emit-module -emit-library -static \
        -emit-module-path "$arch_dir/CaptureTransfer.swiftmodule" Sources/CaptureTransfer/*.swift \
        -o "$arch_dir/libCaptureTransfer.a"
    xcrun swiftc "${swift_flags[@]}" -module-name SwitchCaptures -parse-as-library -I "$arch_dir" \
        Sources/SwitchCaptures/*.swift "$arch_dir/libCaptureTransfer.a" "$arch_dir/SwitchUSB.o" \
        -framework IOKit -o "$arch_dir/SwitchCaptures"
}

echo "Building Switch Captures for Apple silicon and Intel"
build_arch arm64
build_arch x86_64

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
xcrun lipo -create "$work/arm64/SwitchCaptures" "$work/x86_64/SwitchCaptures" -output "$app/Contents/MacOS/SwitchCaptures"

xcrun swift -sdk "$sdk" -module-cache-path "$work/arm64/cache" Scripts/draw-icon.swift \
    "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --keepParent "$app" "$output/Switch-Captures.zip"
echo "$app"
