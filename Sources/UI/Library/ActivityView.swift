#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI wrapper for the system share sheet. Used by bulk selection in the
/// library; the items are temporary file URLs so metadata travels with them.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // On iPad the share sheet is a popover and needs an anchor; presenting
        // it as the root of a SwiftUI sheet gives it a sensible one.
        controller.popoverPresentationController?.sourceView = controller.view
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
