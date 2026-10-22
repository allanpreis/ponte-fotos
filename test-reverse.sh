#!/bin/zsh
set -eu
cd "${0:A:h}"
swiftc -module-cache-path /private/tmp/ponte-fotos-module-cache-v04 -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift Sources/NetworkConnection.swift Sources/ConnectionStore.swift Sources/ImmichManagementAPI.swift Sources/ReverseImport.swift Tests/ReverseImportTests.swift -o /private/tmp/ponte-reverse-tests
/private/tmp/ponte-reverse-tests
