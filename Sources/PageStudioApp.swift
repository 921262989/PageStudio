import SwiftUI

@main
struct PageStudioApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var settingsStore = AppSettingsStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settingsStore)
        }
    }
}
