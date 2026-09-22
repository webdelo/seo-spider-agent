#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Certificate SHA-1 avoids locale-dependent spelling of the Romanian Ș.
identity="67BB530A99900B3EDD7C94CAB03536277D4F7C2F"
release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/AppBundle/Info.plist")"
timestamp="$(date +%Y%m%d-%H%M%S)"
stage_root="$(mktemp -d "${TMPDIR%/}/seospider-release.XXXXXX")"
app="$stage_root/SEOSpiderAgent.app"
output="/Users/daniilspara/Downloads/SEOSpiderAgent-${release_version}-arm64-${timestamp}.dmg"

cleanup() { /bin/rm -rf "$stage_root"; }
trap cleanup EXIT

cd "$project_root"
swift build -c release

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp AppBundle/Info.plist "$app/Contents/Info.plist"
cp AppBundle/Assets/ShareSpider.icns "$app/Contents/Resources/ShareSpider.icns"
cp .build/release/SEOSpiderAgent "$app/Contents/MacOS/SEOSpiderAgent"
ditto .build/arm64-apple-macosx/release/SEOSpiderAgent_ShareSpider.bundle "$app/Contents/Resources/SEOSpiderAgent_ShareSpider.bundle"

# The embedded Node executable requires its own minimal hardened-runtime
# permissions. Never grant get-task-allow in a distribution build.
codesign --force --timestamp --options runtime --entitlements AppBundle/NodeRuntime.entitlements --sign "$identity" "$app/Contents/Resources/SEOSpiderAgent_ShareSpider.bundle/Runtime/node"
codesign --force --timestamp --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

hdiutil create -volname "SEOSpiderAgent" -srcfolder "$app" -ov -format UDZO "$output"
echo "$output"
