import SwiftUI
import ServiceManagement
import NORMAUI
import NORMAClient
@main struct NORMAApp: App {
    @State private var model: AppModel
    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("--demo")
        _model = State(initialValue: AppModel(client: demo ? MockResearchClient() : XPCResearchClient(), demo: demo))
        if !demo {
            do {
                let service = SMAppService.agent(plistName: "app.norma.research.plist")
                if ProcessInfo.processInfo.arguments.contains("--unregister-service") {
                    if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
                    print("Research service unregistered")
                    exit(0)
                }
                if ProcessInfo.processInfo.arguments.contains("--service-status") {
                    print("Research service status: " + String(service.status.rawValue))
                    exit(0)
                }
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
            } catch { NSLog("NORMA background service registration failed: %@", error.localizedDescription) }
        }
    }
    var body: some Scene {
        WindowGroup { NORMAAppShell(model: model) }
            .defaultSize(width: 1440, height: 900)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("刷新") { Task { await model.refresh() } }.keyboardShortcut("r")
                    Button("账户") { model.showWelcome = true }
                }
            }
    }
}
