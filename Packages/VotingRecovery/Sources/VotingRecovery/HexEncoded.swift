import Foundation

extension Data {
    /// Lowercase hex, two characters per byte. Named apart from the app's
    /// `hexString` so a test importing both modules sees no ambiguity.
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
