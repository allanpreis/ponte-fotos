#!/bin/zsh
set -eu
cd "${0:A:h}"
CACHE=/private/tmp/ponte-fotos-media-module-cache
for test in ExternalMediaTests ExternalVideoTests; do
  swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library Sources/Metadata.swift Sources/Immich.swift Sources/ExternalMedia.swift "Tests/$test.swift" -o "/private/tmp/ponte-$test"
  "/private/tmp/ponte-$test"
done
