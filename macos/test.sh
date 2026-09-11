#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/swift-module-cache
xcrun swiftc -parse-as-library macos/Usage.swift macos/Authentication.swift macos/tests/Tests.swift \
  -module-cache-path "$PWD/.build/swift-module-cache" -framework Security -lsqlite3 -o .build/usage-tests
.build/usage-tests "$@"
xcrun swiftc -parse-as-library macos/Usage.swift macos/Authentication.swift macos/AppModel.swift macos/tests/ModelTests.swift \
  -module-cache-path "$PWD/.build/swift-module-cache" -framework AppKit -framework SwiftUI -lsqlite3 -o .build/model-tests
.build/model-tests
bash macos/tests/release-tests.sh
