import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case features
    case general
    case shortcuts
    case excludedApps
    case windowSlots
    case usageHeatmap
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return "Features"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .excludedApps: return "Excluded Apps"
        case .windowSlots: return "Window Slots"
        case .usageHeatmap: return "Usage Heatmap"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .features: return "slider.horizontal.3"
        case .general: return "gear"
        case .shortcuts: return "keyboard"
        case .excludedApps: return "eye.slash"
        case .windowSlots: return "number.square"
        case .usageHeatmap: return "chart.bar.xaxis"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .features

    func showPermissions() {
        selectedTab = .permissions
    }
}

struct SettingsRootView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        ZStack {
            FrostedPanelBackground(
                cornerRadius: 0,
                strokeOpacity: 0,
                shadowOpacity: 0
            )
            .ignoresSafeArea()

            NavigationSplitView {
                List(selection: $navigation.selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
            } detail: {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationTitle("Settings")
                    .toolbarTitleDisplayMode(.inline)
                    .scrollContentBackground(.hidden)
            }
            .navigationSplitViewStyle(.balanced)
            .background(Color.clear)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(SettingsWindowConfiguratorView())
        .environmentObject(appState)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            navigation.selectedTab = .features
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedTab {
        case .features:
            FeaturesSettingsView()
        case .general:
            GeneralSettingsView()
        case .shortcuts:
            ShortcutSettingsView()
        case .excludedApps:
            ExcludedAppsSettingsView()
        case .windowSlots:
            WindowSlotsSettingsView()
        case .usageHeatmap:
            HeatmapSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .about:
            AboutView()
        }
    }
}
