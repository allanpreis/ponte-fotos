import SwiftUI

private enum PFSettingsSection: String, CaseIterable, Identifiable {
    case connection = "Conexão", accounts = "Contas e API", appearance = "Aparência"
    var id: String { rawValue }
}
@MainActor private final class PFSettingsState: ObservableObject {
    @Published var section: PFSettingsSection = .connection
}
struct PFSettingsView: View {
    @ObservedObject var model: LibraryModel
    @Binding var themeRaw: String
    @Binding var glassEnabled: Bool
    @StateObject private var state = PFSettingsState()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Seção de configurações", selection: $state.section) {
                ForEach(PFSettingsSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).controlSize(.large).frame(maxWidth: 500).disabled(model.busy)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch state.section {
                    case .connection: connection
                    case .appearance: appearance
                    case .accounts: accounts
                    }
                }.frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24)
            }
        }.padding(.horizontal, 24).padding(.bottom, 8)
        .onChange(of: state.section) { _, _ in prepareAccounts() }
        .onAppear { prepareAccounts() }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 18) {
            PFCard {
                VStack(alignment: .leading, spacing: 18) {
                    PFSectionHeading("Seu servidor Immich", subtitle: "Configure os endereços e escolha como conectar.", systemImage: "network")
                    Picker("Modo de conexão", selection: $model.profile.mode) {
                        ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 350)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 16) {
                        field("URL local", placeholder: "http://immich.local:2283", value: $model.profile.localAddress)
                        field("URL remota", placeholder: "https://photos.example.com", value: $model.profile.remoteAddress)
                    }
                    Text("No modo Automático, o Wi-Fi de casa prioriza o endereço local. Fora dessa rede, o aplicativo usa o endereço remoto.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            PFCard {
                VStack(alignment: .leading, spacing: 16) {
                    PFSectionHeading("Rede de casa", subtitle: "O nome do Wi-Fi ajuda a escolher o endereço certo.", systemImage: "wifi")
                    field("Nome do Wi-Fi", placeholder: "Nome exato da rede", value: $model.profile.homeSSID)
                    ViewThatFits(in: .horizontal) {
                        HStack { wifiStatus; Spacer(); wifiPermission }
                        VStack(alignment: .leading, spacing: 12) { wifiStatus; wifiPermission }
                    }
                    Text("A permissão de Localização é exigida pelo macOS para ler o nome da rede. O app não usa nem armazena sua posição.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            PFCard {
                VStack(alignment: .leading, spacing: 16) {
                    PFSectionHeading("Conta principal", subtitle: "A chave de API fica protegida no Chaves do macOS.", systemImage: "key")
                    SecureField("Chave de API do Immich", text: $model.apiKey).textFieldStyle(.roundedBorder).controlSize(.large)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { connectionActions }
                        VStack(alignment: .leading, spacing: 12) { connectionActions }
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                    Label(model.connectionLabel, systemImage: model.serverReady ? "checkmark.circle" : "network").font(.callout.weight(.medium))
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.disabled(model.busy)
    }
    private var wifiStatus: some View { Text(model.wifiName.map { "Wi-Fi atual: \($0)" } ?? model.wifiStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private var wifiPermission: some View { Button("Permitir identificar Wi-Fi") { model.requestWifiPermission() } }
    private var connectionActions: some View {
        Group {
            Button("Testar conexão") { Task { await model.testConnection() } }.buttonStyle(.borderedProminent)
            Button("Salvar configuração", systemImage: "key") { model.saveConnection() }.disabled(model.apiKey.isEmpty)
            if model.connectionSaved { Button("Esquecer conexão") { model.forgetConnection() } }
        }
    }
    private func field(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel(title)
        }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            PFCard {
                VStack(alignment: .leading, spacing: 20) {
                    PFSectionHeading("Tema do aplicativo", subtitle: "Escolha sua aparência ou acompanhe o macOS.", systemImage: "circle.lefthalf.filled")
                    HStack(spacing: 12) {
                        ForEach(PFColorTheme.allCases) { theme in
                            Button { themeRaw = theme.rawValue } label: {
                                VStack(spacing: 12) {
                                    Image(systemName: theme.symbol).font(.system(size: 24, weight: .light)).frame(height: 32)
                                    HStack(spacing: 6) {
                                        Text(theme.title).font(.callout.weight(.medium))
                                        if themeRaw == theme.rawValue { Image(systemName: "checkmark.circle.fill").font(.caption) }
                                    }
                                }.foregroundStyle(themeRaw == theme.rawValue ? PFTheme.accent : Color.primary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                                    .background(themeRaw == theme.rawValue ? PFTheme.accent.opacity(0.08) : PFTheme.background, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(themeRaw == theme.rawValue ? PFTheme.accent : PFTheme.separator, lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityLabel("Tema \(theme.title)").accessibilityValue(themeRaw == theme.rawValue ? "Selecionado" : "")
                        }
                    }
                }
            }
            PFCard {
                VStack(alignment: .leading, spacing: 16) {
                    PFSectionHeading("Liquid Glass", subtitle: "Profundidade sutil na navegação e nas ações.", systemImage: "square.on.square")
                    Toggle("Usar transparência e vidro", isOn: $glassEnabled).toggleStyle(.switch)
                    Text(glassDescription).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if reduceTransparency {
                        Label("Reduzir transparência está ativo no macOS. As superfícies permanecem opacas.", systemImage: "accessibility").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("As fotos e os formulários mantêm fundos sólidos para facilitar a leitura. O aplicativo respeita as preferências de acessibilidade do sistema.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private var glassDescription: String {
        if #available(macOS 26.0, *) { return "Neste macOS, o aplicativo usa o efeito Liquid Glass nativo da Apple." }
        return "Neste macOS, o aplicativo usa materiais translúcidos compatíveis. O Liquid Glass nativo requer macOS 26 ou superior."
    }
    private var accounts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let workspace = model.managementModel {
                if workspace.busy { HStack { ProgressView().controlSize(.small); Text(workspace.progress).font(.callout) } }
                if let error = workspace.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                IMAccountSettingsView(model: workspace).disabled(workspace.busy)
            } else {
                PFCard {
                    PFEmptyState("Conecte seu servidor", detail: "Teste a conexão na seção Conexão para adicionar ou revisar as contas do Immich.", systemImage: "person.crop.circle.badge.plus")
                }
                Button("Ir para Conexão") { state.section = .connection }
            }
        }
    }
    private func prepareAccounts() {
        if state.section == .accounts { model.prepareManagementSession() }
    }
}
