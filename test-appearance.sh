#!/bin/zsh
set -eu
cd "${0:A:h}"
swiftc -module-cache-path /private/tmp/ponte-fotos-module-cache-v04 -target arm64-apple-macosx14.0 -swift-version 5 -parse-as-library Sources/DesignSystem.swift Tests/AppearanceTests.swift -o /private/tmp/ponte-appearance-tests
/private/tmp/ponte-appearance-tests
