import Foundation

/// Helper function to escape shell special characters in placeholder values
func escapeShellCharacters(_ input: String) -> String {
    // Only escape the minimal set of characters that would cause issues in shell command arguments
    // These are the characters that would break shell command parsing
    return input.replacingOccurrences(of: "\\", with: "\\\\") // Must be first to avoid double-escaping
               .replacingOccurrences(of: "\"", with: "\\\"")
               .replacingOccurrences(of: "`", with: "\\`")    // Command substitution
               .replacingOccurrences(of: "$", with: "\\$")    // Variable expansion
} 