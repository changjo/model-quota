#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
render_dir="$(mktemp -d "${TMPDIR:-/tmp}/model-quota-render.XXXXXX")"
trap 'rm -rf "$render_dir"' EXIT
output_dir="${1:-$project_dir/.build/ui-previews}"
architecture="$(uname -m)"
compiler_options=(-target "$architecture-apple-macos14.0" -swift-version 5 -Xfrontend -disable-sandbox -module-cache-path "$render_dir/cache")
xcrun swiftc "${compiler_options[@]}" -emit-library -emit-module -module-name ModelQuotaCore \
    Sources/ModelQuotaCore/*.swift -o "$render_dir/libModelQuotaCore.dylib" \
    -emit-module-path "$render_dir/ModelQuotaCore.swiftmodule"
xcrun swiftc "${compiler_options[@]}" -I "$render_dir" -L "$render_dir" -lModelQuotaCore \
    -Xlinker -rpath -Xlinker "$render_dir" Sources/ModelQuota/UsageMeterRow.swift \
    Sources/ModelQuota/UsagePopover.swift \
    Sources/ModelQuota/WeeklyHistogramView.swift \
    Sources/ModelQuota/GeminiQuotaView.swift \
    Sources/ModelQuota/ClaudeQuotaView.swift \
    Sources/ModelQuota/MenuBarGridView.swift \
    Sources/ModelQuota/SettingsView.swift scripts/render-ui.swift -o "$render_dir/render"
"$render_dir/render" "$output_dir"
