#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
mkdir -p .build/module-cache .build/test-sources
# Compile the app once; run each suite in a fresh process so state cannot leak.
python3 - <<'PY'
from pathlib import Path
suites = ['SatsumaTests', 'IntegrationTests', 'InteractionTests', 'ImageConversionTests', 'DocumentTests', 'BatchTests', 'ImageToolsTests', 'MediaIntegrationTests']
for name in suites:
    source = Path('NativeApp/Tests', name + '.swift').read_text().replace('@main ', '').replace('@main\n', '')
    Path('.build/test-sources', name + '.swift').write_text(source)
driver = 'import Foundation\n@main struct AllTests {\n@MainActor static func main() async throws {\nswitch CommandLine.arguments.last {\n'
for name in suites:
    call = 'OpenTangerineTests.main()' if name == 'SatsumaTests' else 'try await ' + name + '.main()'
    driver += 'case "' + name + '": ' + call + '\n'
driver += 'default: fatalError("Choose a test suite")\n}\n}\n}\n'
Path('.build/test-sources/AllTests.swift').write_text(driver)
PY
find NativeApp/Sources .build/test-sources -name '*.swift' ! -path '*/Sources/App.swift' -print0 | xargs -0 xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx$MIN_MACOS" -module-cache-path "$PWD/.build/module-cache" -o .build/all-tests
for suite in SatsumaTests IntegrationTests InteractionTests ImageConversionTests DocumentTests BatchTests ImageToolsTests MediaIntegrationTests; do
  echo "Running $suite"
  .build/all-tests "$suite"
done
