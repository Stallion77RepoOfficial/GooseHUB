#!/bin/bash
# Build the GooseHUB installer app. Engines are fetched and compiled at first launch.
set -euo pipefail
caller=$PWD
hub=$(cd "$(dirname "$0")" && pwd)
cd "$hub"
output=${1:-"$hub/dist/Goose HUB latest.app"}
[[ $output == /* ]] || output=$caller/$output
[[ $output == *.app ]] || { echo 'Output must be an .app directory' >&2; exit 1; }
if ps -axww -o command= | BUNDLE="$output/" awk 'index($0, ENVIRON["BUNDLE"]) { found=1 } END { exit !found }'; then
    echo "The app is in use: $output" >&2
    exit 1
fi
cache=${GOOSE_BUILD_CACHE:-"$HOME/Library/Caches/GooseHUB"}
swift_cache=$cache/GooseHUB/swift
xcrun swift build --package-path "$hub" --scratch-path "$swift_cache" -c release --arch arm64
bin=$(xcrun swift build --package-path "$hub" --scratch-path "$swift_cache" -c release --arch arm64 --show-bin-path)
icon=$cache/GooseHUB/GooseHUB.icns
mkdir -p "$(dirname "$icon")" "$(dirname "$output")"
if [[ ! -f $icon || logo.png -nt $icon ]]; then xcrun swift scripts/make-icon.swift logo.png "$icon"; fi
stage=$(mktemp -d "$(dirname "$output")/.goosehub-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app=$stage/GooseHUB.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Bootstrap"
cp Resources/Info.plist "$app/Contents/"
cp "$bin/GooseHUB" "$bin/goosehub-cli" "$app/Contents/MacOS/"
cp LICENSE "$app/Contents/Resources/"
cp "$icon" "$app/Contents/Resources/GooseHUB.icns"
sips -z 512 512 logo.png --out "$app/Contents/Resources/GooseHUB-logo.png" >/dev/null
cp scripts/install-engines.py Resources/engine-lock.json Resources/Wine.entitlements Resources/GooseHUB.entitlements \
    "$app/Contents/Resources/Bootstrap/"
codesign --force --sign - --entitlements Resources/GooseHUB.entitlements "$app"
codesign --verify --deep --strict "$app"
[[ ! -e $output ]] || rm -rf "$output"
mv "$app" "$output"
echo "Built installer app without engines: $output"
