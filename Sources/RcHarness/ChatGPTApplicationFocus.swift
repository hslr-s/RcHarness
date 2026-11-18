import Foundation

/// Decides whether ChatGPT should be focused directly or launched first.
/// AppKit-specific launch and activation are injected so this decision stays testable.
@MainActor
enum ChatGPTApplicationFocus {
    static func perform(
        installedURL: URL?,
        runningProcessID: Int32?,
        focusRunning: @escaping (Int32) -> Void,
        launch: @escaping (URL, @escaping (Int32?) -> Void) -> Void
    ) {
        guard let installedURL else { return }
        if let runningProcessID {
            focusRunning(runningProcessID)
            return
        }
        launch(installedURL) { processID in
            guard let processID else { return }
            focusRunning(processID)
        }
    }
}
