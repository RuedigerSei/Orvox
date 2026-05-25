import SwiftUI

enum SidebarItem: String, Hashable {
    case newJob       = "New Job"
    case jobQueue     = "Job Queue"
    case voices       = "Voice Profiles"
    case outputFiles  = "Output Files"
    case settings     = "Settings"
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .newJob

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection {
            case .newJob, nil:  ConvertView()
            case .jobQueue:     JobQueueView()
            case .voices:       VoiceLibraryView()
            case .outputFiles:  OutputFilesView()
            case .settings:     SettingsView()
            }
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Convert") {
                Label("New Job",    systemImage: "doc.badge.plus")
                    .tag(SidebarItem.newJob)
                Label("Job Queue",  systemImage: "list.bullet.clipboard")
                    .tag(SidebarItem.jobQueue)
            }
            Section("Library") {
                Label("Voice Profiles",  systemImage: "waveform.circle")
                    .tag(SidebarItem.voices)
                Label("Output Files",    systemImage: "checkmark.circle")
                    .tag(SidebarItem.outputFiles)
            }
            Section("App") {
                Label("Settings", systemImage: "gear")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
    }
}
