import Foundation
import Photos

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Small, shared vocabulary for the photo-library permission states.
///
/// iOS apps are expected to explain *why* they need the library before the
/// system prompt, to keep working (and say so) when the person grants only a
/// selection, and to offer a route back to Settings once access has been
/// refused. Keeping those strings in one place means onboarding, the library
/// and Settings all describe the same state the same way.
enum PhotoAccess {
    /// The state PhotoKit reports for read/write access, which is what Backu
    /// needs to read originals and write downloads back to the library.
    @MainActor
    static var status: PHAuthorizationStatus {
        PhotoLibraryService.authorizationStatus
    }

    /// Opens the app's page in the system Settings app. Used when access has
    /// already been refused: iOS will not show the prompt a second time, so the
    /// only way to grant it is Settings.
    @MainActor
    static func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }
}

extension PHAuthorizationStatus {
    /// Short state name, used as the Settings subtitle.
    var photoAccessTitle: String {
        switch self {
        case .authorized: return "Full access"
        case .limited: return "Limited access"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    /// One sentence that explains what the state means for the library.
    var photoAccessDetail: String {
        switch self {
        case .authorized:
            return "Backu can see and back up every photo and video."
        case .limited:
            return "Backu can only see the photos you selected."
        case .denied:
            return "Backu cannot see your library. Allow access in Settings to back up new photos."
        case .restricted:
            return "Photo access is restricted on this device."
        case .notDetermined:
            return "Backu has not asked for access to your photo library yet."
        @unknown default:
            return "Photo access is unavailable."
        }
    }
}
