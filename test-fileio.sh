#!/bin/zsh
set -eu
cd "${0:A:h}"
swiftc -module-cache-path /private/tmp/ponte-fotos-module-cache-v04 -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift Sources/TransferFileIO.swift Tests/TransferFileIOTests.swift -o /private/tmp/ponte-fileio-tests
/private/tmp/ponte-fileio-tests
