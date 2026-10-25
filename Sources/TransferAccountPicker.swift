import SwiftUI

/// Account selection stays separate from the album destination. Identifiers and keys are never labels.
struct PFTransferAccountPicker: View {
    @ObservedObject private var localization = PFLocalization.shared
    @ObservedObject var model: LibraryModel
    @StateObject private var avatarLoader = PFAccountAvatarLoader()
    private var selectedName: String {
        model.selectedTransferAccountID.isEmpty ? model.primaryAccountLabel :
            (model.transferAccounts.first { $0.id == model.selectedTransferAccountID }?.displayName ?? L("Conta não validada"))
    }
    private var avatarContext: PFAccountAvatarContext? {
        guard let connection = model.transferConnection else { return nil }
        if model.selectedTransferAccountID.isEmpty {
            guard connection.credential.key == model.apiKey else { return nil }
        } else {
            guard connection.userID == model.selectedTransferAccountID else { return nil }
        }
        return PFAccountAvatarContext(profileID: connection.profileID, address: connection.address,
            userID: connection.userID, key: connection.credential.key)
    }
    var body: some View {
        Menu {
            Button(model.primaryAccountLabel) { model.selectedTransferAccountID = "" }
            ForEach(model.transferAccounts) { account in
                Button(account.displayName) { model.selectedTransferAccountID = account.id }
            }
            Divider()
            Button(L("Validar conta")) { Task { await model.testTransferConnection() } }
            Button(L("Atualizar contas")) { model.reloadTransferAccounts() }
        } label: {
            Label {
                Text(selectedName).font(.system(size: 13)).lineLimit(1)
            } icon: {
                let image = avatarLoader.contextKey == avatarContext?.cacheKey ? avatarLoader.image : nil
                Image(nsImage: PFAccountAvatar.sidebarImage(name: selectedName, image: image))
                    .renderingMode(.original)
            }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .disabled(model.busy)
            .accessibilityLabel(L("Conta desta transferência"))
            .accessibilityValue(selectedName)
            .onAppear { model.reloadTransferAccounts() }
            .task(id: avatarContext?.cacheKey) { await avatarLoader.load(avatarContext) }
    }
}
