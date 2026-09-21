#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --disable-sandbox -c release
binary_dir="$(swift build --disable-sandbox -c release --show-bin-path)"
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.app-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Codex Usage.app"
destination="$project_dir/dist/Codex Usage.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/CodexUsage" "$app_dir/Contents/MacOS/CodexUsage"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp LICENSE "$app_dir/Contents/Resources/LICENSE"
xcrun actool Resources/AppIcon.icon --compile "$app_dir/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$project_dir/.build/AppIconInfo.plist" \
    --output-format human-readable-text
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
cp INSTALL.md "$project_dir/dist/INSTALL.md"
cp LICENSE "$project_dir/dist/LICENSE"
# Replace only after verification; obsolete resources cannot leak into a new build.
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging_dir/previous.app"
fi
mv "$app_dir" "$destination"
printf 'Built: %s\n' "$destination"
