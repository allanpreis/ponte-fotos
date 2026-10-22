#!/bin/zsh
set -eu
cd "${0:A:h}"
CACHE=/private/tmp/ponte-fotos-module-cache-v04
BASE=(Sources/Metadata.swift Sources/Immich.swift Sources/NetworkConnection.swift Sources/ConnectionStore.swift Sources/ImmichManagementAPI.swift)
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library $BASE Sources/ImmichDuplicates.swift Tests/ImmichDuplicatesTests.swift -o /private/tmp/ponte-native-duplicate-final
/private/tmp/ponte-native-duplicate-final
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library $BASE Sources/ImmichOrganization.swift Tests/ImmichOrganizationTests.swift -o /private/tmp/ponte-native-organization-final
/private/tmp/ponte-native-organization-final
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library $BASE Sources/ConnectionHistory.swift Sources/ImmichDuplicates.swift Sources/ImmichOrganization.swift Sources/DesignSystem.swift Sources/ImmichWorkspace.swift Tests/ImmichWorkspaceTests.swift -o /private/tmp/ponte-native-workspace-final
/private/tmp/ponte-native-workspace-final
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library $BASE Tests/ImmichManagementAPITests.swift -o /private/tmp/ponte-native-api-final
/private/tmp/ponte-native-api-final
swiftc -module-cache-path "$CACHE" -swift-version 5 -parse-as-library $BASE Sources/ConnectionHistory.swift Sources/ImmichDuplicates.swift Sources/ImmichOrganization.swift Sources/DesignSystem.swift Sources/ImmichWorkspace.swift Tests/WorkspaceSessionTests.swift -o /private/tmp/ponte-workspace-session-tests
/private/tmp/ponte-workspace-session-tests
