import Foundation

/// Canonical links used by the in-app support card and the README.
enum ProjectLinks {
    static let repository = URL(string: "https://github.com/oscartbeaumont/backu")!
    static let sponsors = URL(string: "https://github.com/sponsors/oscartbeaumont")!
    static let issues = URL(string: "https://github.com/oscartbeaumont/backu/issues")!
    static let license = URL(string: "https://github.com/oscartbeaumont/backu/blob/main/LICENSE")!
    /// App Store Connect requires a privacy policy that is also reachable from
    /// inside the app, not only from the listing.
    static let privacyPolicy = URL(string: "https://backu.otbeaumont.me/privacy")!
    static let support = URL(string: "https://backu.otbeaumont.me/support")!
}
