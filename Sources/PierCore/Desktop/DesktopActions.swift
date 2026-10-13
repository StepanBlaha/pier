import Foundation
import AppKit

public enum Clipboard {
    public static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
