import ApplicationServices

enum SecureFieldDetector {
    static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subrole
        ) == .success && subrole as? String == kAXSecureTextFieldSubrole as String
    }

}
