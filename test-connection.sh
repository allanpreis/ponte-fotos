#!/bin/zsh
set -eu
cd "${0:A:h}"
CACHE=/private/tmp/ponte-probe-cache-1021
for test in MetadataTests ServerVersionTests ReviewAlbumTests ConnectionProbeTests; do
  swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift "Tests/$test.swift" -o "/private/tmp/ponte-$test"
  "/private/tmp/ponte-$test"
done
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift Sources/NetworkConnection.swift Tests/NetworkConnectionTests.swift -o /private/tmp/ponte-network-policy-tests
/private/tmp/ponte-network-policy-tests
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift Sources/NetworkConnection.swift Sources/ConnectionResolver.swift Tests/ConnectionResolverTests.swift -o /private/tmp/ponte-network-resolver-tests
/private/tmp/ponte-network-resolver-tests
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift Sources/NetworkConnection.swift Sources/ConnectionHistory.swift Sources/ConnectionStore.swift Tests/ConnectionHistoryTests.swift -o /private/tmp/ponte-connection-history-tests
/private/tmp/ponte-connection-history-tests
