// Main.swift - MacPulse: the unified app shell.
// Sidebar navigation across all six tools; models are created once here so
// scans survive switching panes. The menu bar item and screenshot organizer
// live in AppDelegate (StatusBar.swift) and keep running when the window closes.

import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case dashboard, clean, files, uninstall, startup, shots, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .clean: return "Clean Storage"
        case .files: return "Duplicates & Large Files"
        case .uninstall: return "Uninstall Apps"
        case .startup: return "Startup Items"
        case .shots: return "Screenshots"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.needle"
        case .clean: return "sparkles"
        case .files: return "doc.on.doc"
        case .uninstall: return "trash"
        case .startup: return "power"
        case .shots: return "camera.viewfinder"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @State private var pane: Pane? = .dashboard
    @StateObject private var dashboard = DashboardModel()
    @StateObject private var clean = CleanModel()
    @StateObject private var files = FilesModel()
    @StateObject private var uninstall = UninstallModel()
    @StateObject private var startup = StartupModel()

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch pane ?? .dashboard {
            case .dashboard: DashboardView(model: dashboard)
            case .clean: CleanView(model: clean)
            case .files: FilesView(model: files)
            case .uninstall: UninstallView(model: uninstall)
            case .startup: StartupView(model: startup)
            case .shots: ShotsView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle("MacPulse")
    }
}

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("MacPulse") {
            MainView()
        }
    }
}
