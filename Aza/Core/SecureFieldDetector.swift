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

    static func isTextInput(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        ) == .success, let role = role as? String else {
            return false
        }
        return role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
    }
}
