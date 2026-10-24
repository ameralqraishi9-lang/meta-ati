import SwiftUI
import MWDATCore

@main
struct MetaStudyApp: App {
    private let startupError: String?

    init() {
        do { try Wearables.configure(); startupError = nil }
        catch { startupError = error.localizedDescription }
    }

    var body: some Scene {
        WindowGroup {
            if let startupError {
                ContentUnavailableView("Glasses setup failed", systemImage: "eyeglasses",
                    description: Text(startupError))
            } else {
                StudyView()
            }
        }
    }
}
