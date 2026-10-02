import Domain
import Networking
import SwiftUI
import UI

@main
struct MessengerApp: App {
    private let configuration: Result<ServerConfig, ServerConfig.LoadError>

    init() {
        do {
            configuration = .success(try ServerConfig(infoDictionary: Bundle.main.infoDictionary ?? [:]))
        } catch {
            configuration = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch configuration {
            case .success:
                // SKELETON: services are wired in the composition root from Phase 2 on.
                RootView(authService: nil)
            case .failure:
                ContentUnavailableView(
                    "Unable to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This build is misconfigured. Please install the latest version.")
                )
            }
        }
    }
}
