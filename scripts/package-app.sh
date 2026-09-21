#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
./scripts/build-app.sh

app_dir="$project_dir/dist/Codex Usage.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architecture="$(lipo -archs "$app_dir/Contents/MacOS/CodexUsage")"
case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Unsupported archive architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
archive_name="Codex-Usage-$version-macos-$architecture.zip"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir "$staging_dir/Codex Usage"
ditto "$app_dir" "$staging_dir/Codex Usage/Codex Usage.app"
cp INSTALL.md LICENSE "$staging_dir/Codex Usage/"
ditto -c -k --sequesterRsrc --keepParent "$staging_dir/Codex Usage" "$staging_dir/$archive_name"

# Validate the actual archive, not just the directory it was created from.
mkdir "$staging_dir/unpacked"
ditto -x -k "$staging_dir/$archive_name" "$staging_dir/unpacked"
unpacked="$staging_dir/unpacked/Codex Usage"
codesign --verify --strict "$unpacked/Codex Usage.app"
cmp "$app_dir/Contents/Info.plist" "$unpacked/Codex Usage.app/Contents/Info.plist"
cmp INSTALL.md "$unpacked/INSTALL.md"
cmp LICENSE "$unpacked/LICENSE"
cmp LICENSE "$unpacked/Codex Usage.app/Contents/Resources/LICENSE"
mv "$staging_dir/$archive_name" "$project_dir/dist/$archive_name"
cd "$project_dir/dist"
shasum -a 256 "$archive_name" > "$archive_name.sha256"
printf 'Packaged: %s/dist/%s\n' "$project_dir" "$archive_name"
