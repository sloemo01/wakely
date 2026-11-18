#!/bin/bash
# Isolated actual-menu/coach tests. Never links engines or launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_CACHE="${WAKELY_BUILD_CACHE:-$HOME/Library/Caches/Wakely/build}"
mkdir -p "$BUILD_CACHE"
mkdir -p build/tests
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/HighlightTourUI.swift').read_text()
coach = source[source.index('struct HighlightTourCoach: View {'):source.index('/// This is the production inline control')]
Path('build/tests/MenuTourActualCoach.swift').write_text('import SwiftUI\nimport AppKit\n' + coach)
pixel = Path('Sources/PixelUI.swift').read_text()
Path('build/tests/MenuTourActualPixel.swift').write_text(pixel[:pixel.index('/// A faint checkerboard')])
PY
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$BUILD_CACHE" -framework AppKit -framework SwiftUI \
  Sources/OnboardingPolicy.swift Sources/HighlightTourStep.swift Sources/GuideCoordinator.swift \
  Sources/Typography.swift build/tests/MenuTourActualPixel.swift Sources/AppMotion.swift Sources/GooShape.swift \
  Sources/MenuIconPolicy.swift Sources/KeepAwakeSelection.swift Sources/GooMenuView.swift \
  Tests/MenuTourTestSupport.swift build/tests/MenuTourActualCoach.swift "${1:-Tests/MenuTourInteractionTests.swift}" \
  -o build/tests/menu-tour-interaction
build/tests/menu-tour-interaction
