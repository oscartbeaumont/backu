import SwiftUI

@main
struct BackuApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    @UIApplicationDelegateAdaptor(BackuAppDelegate.self) private var delegate
    #endif

    init() {
        #if os(iOS)
        BackupScheduler.register(expire: {
            Task { @MainActor in AppModel.shared?.backup.cancel() }
        }) { done in
            Task { @MainActor in
                await AppModel.shared?.scanLibrary()
                await AppModel.shared?.runAutoBackup(reason: "background")
                await AppModel.shared?.backup.awaitCompletion()
                done()
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await app.handleActivation() }
                    } else if phase == .background {
                        app.catalog.saveNow()
                        app.servers.persistNow()
                        BackupScheduler.schedule()
                    }
                }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Back Up Now") { app.startBackup() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Scan Library") {
                    Task { await app.scanLibrary(force: true) }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
        #endif
    }
}

#if os(iOS)
final class BackuAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundUploader.sessionIdentifier {
            BackgroundUploader.shared.handleEvents(completionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}
#endif
