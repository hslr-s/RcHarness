import AppKit
import SwiftUI

/// Releases automatic footer tracking as soon as the user starts scrolling.
@MainActor
struct MacroStepScrollObserver: NSViewRepresentable {
    var onScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("macro-add-step")
        let coordinator = context.coordinator
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main
        ) { [weak view, weak coordinator] notification in
            MainActor.assumeIsolated {
                guard let view, let scroll = notification.object as? NSScrollView,
                      view.enclosingScrollView === scroll else { return }
                coordinator?.onScroll()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor
    final class Coordinator {
        var onScroll: () -> Void
        var observer: NSObjectProtocol?

        init(onScroll: @escaping () -> Void) { self.onScroll = onScroll }
    }
}
