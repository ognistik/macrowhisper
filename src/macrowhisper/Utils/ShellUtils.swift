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

/// Helper function to escape AppleScript special characters in placeholder values
func escapeAppleScriptString(_ input: String) -> String {
    // Escape characters that would break AppleScript string literals
    return input.replacingOccurrences(of: "\\", with: "\\\\") // Must be first to avoid double-escaping
               .replacingOccurrences(of: "\"", with: "\\\"")
} 

/// Helper function to escape JSON special characters in placeholder values
/// This is used for special cases where users need to embed placeholder content in JSON strings
func escapeJsonString(_ input: String) -> String {
    // Escape characters that would break JSON string literals
    return input.replacingOccurrences(of: "\\", with: "\\\\") // Must be first to avoid double-escaping
               .replacingOccurrences(of: "\"", with: "\\\"")
               .replacingOccurrences(of: "\r", with: "\\r")
               .replacingOccurrences(of: "\n", with: "\\n")
               .replacingOccurrences(of: "\t", with: "\\t")
               .replacingOccurrences(of: "\u{08}", with: "\\b") // backspace
               .replacingOccurrences(of: "\u{0C}", with: "\\f") // form feed
}

/// Helper function to URL-encode placeholder values for URL actions
/// This ensures only the placeholder content gets URL-encoded while preserving the user's URL structure
func escapeUrlPlaceholder(_ input: String) -> String {
    // URL-encode the placeholder value using a restrictive character set
    // This ensures all special characters that could break URL parsing are properly encoded
    // Only allow alphanumeric characters, hyphens, underscores, and periods
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return input.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? input
} 