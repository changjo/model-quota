#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
render_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-render.XXXXXX")"
trap 'rm -rf "$render_dir"' EXIT
output_dir="${1:-$project_dir/.build/ui-previews}"
architecture="$(uname -m)"
compiler_options=(-target "$architecture-apple-macos14.0" -swift-version 5 -Xfrontend -disable-sandbox -module-cache-path "$render_dir/cache")
xcrun swiftc "${compiler_options[@]}" -emit-library -emit-module -module-name CodexUsageCore \
    Sources/CodexUsageCore/*.swift -o "$render_dir/libCodexUsageCore.dylib" \
    -emit-module-path "$render_dir/CodexUsageCore.swiftmodule"
xcrun swiftc "${compiler_options[@]}" -I "$render_dir" -L "$render_dir" -lCodexUsageCore \
    -Xlinker -rpath -Xlinker "$render_dir" Sources/CodexUsage/UsagePopover.swift \
    Sources/CodexUsage/SettingsView.swift scripts/render-ui.swift -o "$render_dir/render"
"$render_dir/render" "$output_dir"
