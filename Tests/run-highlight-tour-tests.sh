#!/bin/bash
# Focused model/coordinator tests only. Never builds or launches the application.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_CACHE="${WAKELY_BUILD_CACHE:-$HOME/Library/Caches/Wakely/build}"
mkdir -p "$BUILD_CACHE"
SWIFTC=(xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$BUILD_CACHE")
mkdir -p build/tests
"${SWIFTC[@]}" Sources/OnboardingPolicy.swift Tests/OnboardingPolicyTests.swift -o build/tests/highlight-onboarding-policy
build/tests/highlight-onboarding-policy
"${SWIFTC[@]}" Sources/OnboardingPolicy.swift Sources/HighlightTourStep.swift Tests/HighlightTourTests.swift -o build/tests/highlight-tour
build/tests/highlight-tour
"${SWIFTC[@]}" -framework AppKit Sources/OnboardingPolicy.swift Sources/HighlightTourStep.swift Sources/GuideCoordinator.swift Tests/GuideCoordinatorTests.swift -o build/tests/highlight-guide-coordinator
build/tests/highlight-guide-coordinator
# The historical five-page guide catalog remains independent of the active tour.
"${SWIFTC[@]}" Sources/ComponentCatalog.swift Sources/GuideContent.swift Tests/GuideContentTests.swift -o build/tests/highlight-legacy-guide-content
build/tests/highlight-legacy-guide-content
