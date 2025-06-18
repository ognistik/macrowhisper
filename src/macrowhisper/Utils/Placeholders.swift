import Foundation
import Cocoa

// Function to process LLM result based on XML placeholders in the action
func processXmlPlaceholders(action: String, llmResult: String) -> (String, [String: String]) {
    var cleanedLlmResult = llmResult
    var extractedTags: [String: String] = [:]
    
    // First, identify which XML tags are requested in the action
    let placeholderPattern = "\\{\\{xml:([A-Za-z0-9_]+)\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [])
    
    var requestedTags: Set<String> = []
    
    // Find all XML placeholders in the action
    if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches {
            if let tagNameRange = Range(match.range(at: 1), in: action) {
                let tagName = String(action[tagNameRange])
                requestedTags.insert(tagName)
            }
        }
    }
    
    // If no XML tags are requested, return the original LLM result
    if requestedTags.isEmpty {
        return (cleanedLlmResult, extractedTags)
    }
    
    // For each requested tag, extract content and remove from LLM result
    for tagName in requestedTags {
        // Pattern to match the specific XML tag
        let tagPattern = "<\(tagName)>(.*?)</\(tagName)>"
        let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.dotMatchesLineSeparators])
        
        // Find the tag in the LLM result
        if let match = tagRegex?.firstMatch(in: cleanedLlmResult, options: [], range: NSRange(cleanedLlmResult.startIndex..., in: cleanedLlmResult)),
           let contentRange = Range(match.range(at: 1), in: cleanedLlmResult),
           let fullMatchRange = Range(match.range, in: cleanedLlmResult) {
            
            // Extract content and clean it
            var content = String(cleanedLlmResult[contentRange])
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Store the cleaned content
            extractedTags[tagName] = content
            
            // Remove the XML tag and its content from the result
            cleanedLlmResult.replaceSubrange(fullMatchRange, with: "")
        }
    }
    
    // Clean up the LLM result after removing all requested tags
    // Remove any consecutive empty lines
    cleanedLlmResult = cleanedLlmResult.replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
    
    // Trim leading and trailing whitespace
    cleanedLlmResult = cleanedLlmResult.trimmingCharacters(in: .whitespacesAndNewlines)
    
    return (cleanedLlmResult, extractedTags)
}

// Function to replace XML placeholders in an action string
func replaceXmlPlaceholders(action: String, extractedTags: [String: String]) -> String {
    var result = action
    
    // Find all XML placeholders using regex
    let pattern = "\\{\\{xml:([A-Za-z0-9_]+)\\}\\}"
    let regex = try? NSRegularExpression(pattern: pattern, options: [])
    
    // Get all matches
    if let matches = regex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches.reversed() {
            if let tagNameRange = Range(match.range(at: 1), in: action),
               let fullMatchRange = Range(match.range, in: action) {
                
                let tagName = String(action[tagNameRange])
                
                // Replace the placeholder with the extracted content if available and not empty
                if let content = extractedTags[tagName], !content.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: content)
                } else {
                    // If content is missing or empty, remove the placeholder entirely
                    result.replaceSubrange(fullMatchRange, with: "")
                }
            }
        }
    }
    
    return result
}

// MARK: - Dynamic Placeholder Expansion (Refactored)
/// Expands dynamic placeholders in the form {{key}} and (new) {{date:format}} in the action string.
func processDynamicPlaceholders(action: String, metaJson: [String: Any]) -> String {
    var result = action
    var metaJson = metaJson // Make mutable copy
    
    // Updated regex for {{key}}, {{date:...}}, and {{key||regex||replacement}} with multiple replacements
    let placeholderPattern = "\\{\\{([A-Za-z0-9_]+)(?::([^|}]+))?(?:\\|\\|(.+?))?\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [])
    
    // Check if this is an AppleScript action by looking for "tell application" or "osascript"
    let isAppleScript = action.contains("tell application") || action.contains("osascript")
    
    // --- BEGIN: FrontApp Placeholder Logic ---
    // Only fetch the front app if the placeholder is present and not already in metaJson
    if action.contains("{{frontApp}}") && metaJson["frontApp"] == nil {
        // Use frontAppName from metaJson if present (set by trigger evaluation)
        var appName: String? = nil
        if let fromTrigger = metaJson["frontAppName"] as? String, !fromTrigger.isEmpty {
            appName = fromTrigger
        } else if let app = lastDetectedFrontApp {
            appName = app.localizedName
        } else {
            // Fetch the frontmost application (synchronously, main thread safe)
            if Thread.isMainThread {
                let frontApp = NSWorkspace.shared.frontmostApplication
                lastDetectedFrontApp = frontApp
                appName = frontApp?.localizedName
            } else {
                var fetchedApp: NSRunningApplication?
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    fetchedApp = NSWorkspace.shared.frontmostApplication
                    lastDetectedFrontApp = fetchedApp
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 0.1)
                appName = fetchedApp?.localizedName
            }
        }
        metaJson["frontApp"] = appName ?? ""
        logDebug("[FrontAppPlaceholder] Set frontApp in metaJson: \(appName ?? "<none>")")
    }
    // --- END: FrontApp Placeholder Logic ---
    
    if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: action),
                  let fullMatchRange = Range(match.range, in: action) else { continue }
            let key = String(action[keyRange])
            
            // Extract regex replacements if present
            var regexReplacements: [(regex: String, replacement: String)] = []
            if match.numberOfRanges > 3, let replacementRange = Range(match.range(at: 3), in: action) {
                let replacementString = String(action[replacementRange])
                let parts = replacementString.components(separatedBy: "||")
                // Process pairs of regex and replacement
                for i in stride(from: 0, to: parts.count - 1, by: 2) {
                    if i + 1 < parts.count {
                        let regex = parts[i]
                        let replacement = parts[i + 1]
                        regexReplacements.append((regex: regex, replacement: replacement))
                    }
                }
            }
            
            // Check for date placeholder
            if key == "date", match.numberOfRanges > 2, let formatRange = Range(match.range(at: 2), in: action) {
                let format = String(action[formatRange])
                var replacement: String
                switch format {
                case "short":
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .none
                    replacement = formatter.string(from: Date())
                case "long":
                    let formatter = DateFormatter()
                    formatter.dateStyle = .long
                    formatter.timeStyle = .none
                    replacement = formatter.string(from: Date())
                default:
                    // UTS 35 custom format
                    let formatter = DateFormatter()
                    formatter.setLocalizedDateFormatFromTemplate(format)
                    replacement = formatter.string(from: Date())
                }
                
                // Apply regex replacements if any
                replacement = applyRegexReplacements(to: replacement, replacements: regexReplacements)
                
                // Use appropriate escaping based on action type
                let escapedReplacement = isAppleScript ? escapeAppleScriptString(replacement) : escapeShellCharacters(replacement)
                result.replaceSubrange(fullMatchRange, with: escapedReplacement)
                continue
            }
            // Handle swResult
            else if key == "swResult" {
                var value: String
                if let llm = metaJson["llmResult"] as? String, !llm.isEmpty {
                    value = llm
                } else if let res = metaJson["result"] as? String, !res.isEmpty {
                    value = res
                } else {
                    value = ""
                }
                
                // Apply regex replacements if any
                value = applyRegexReplacements(to: value, replacements: regexReplacements)
                
                // Use appropriate escaping based on action type
                let escapedValue = isAppleScript ? escapeAppleScriptString(value) : escapeShellCharacters(value)
                result.replaceSubrange(fullMatchRange, with: escapedValue)
            } else if let jsonValue = metaJson[key] {
                var value: String
                if let stringValue = jsonValue as? String {
                    value = stringValue
                } else if let numberValue = jsonValue as? NSNumber {
                    value = numberValue.stringValue
                } else if let boolValue = jsonValue as? Bool {
                    value = boolValue ? "true" : "false"
                } else if jsonValue is NSNull {
                    value = ""
                } else if let jsonData = try? JSONSerialization.data(withJSONObject: jsonValue),
                          let jsonString = String(data: jsonData, encoding: .utf8) {
                    value = jsonString
                } else {
                    value = String(describing: jsonValue)
                }
                
                // Apply regex replacements if any
                value = applyRegexReplacements(to: value, replacements: regexReplacements)
                
                // Use appropriate escaping based on action type
                let escapedValue = isAppleScript ? escapeAppleScriptString(value) : escapeShellCharacters(value)
                result.replaceSubrange(fullMatchRange, with: escapedValue)
            } else {
                // Key doesn't exist in metaJson, remove the placeholder
                result.replaceSubrange(fullMatchRange, with: "")
            }
        }
    }
    return result
}

/// Expands dynamic placeholders with context-aware escaping based on action type
func processDynamicPlaceholders(action: String, metaJson: [String: Any], actionType: ActionType) -> String {
    var result = action
    var metaJson = metaJson // Make mutable copy
    
    // Updated regex for {{key}}, {{date:...}}, and {{key||regex||replacement}} with multiple replacements
    let placeholderPattern = "\\{\\{([A-Za-z0-9_]+)(?::([^|}]+))?(?:\\|\\|(.+?))?\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [])
    
    // --- BEGIN: FrontApp Placeholder Logic ---
    // Only fetch the front app if the placeholder is present and not already in metaJson
    if action.contains("{{frontApp}}") && metaJson["frontApp"] == nil {
        // Use frontAppName from metaJson if present (set by trigger evaluation)
        var appName: String? = nil
        if let fromTrigger = metaJson["frontAppName"] as? String, !fromTrigger.isEmpty {
            appName = fromTrigger
        } else if let app = lastDetectedFrontApp {
            appName = app.localizedName
        } else {
            // Fetch the frontmost application (synchronously, main thread safe)
            if Thread.isMainThread {
                let frontApp = NSWorkspace.shared.frontmostApplication
                lastDetectedFrontApp = frontApp
                appName = frontApp?.localizedName
            } else {
                var fetchedApp: NSRunningApplication?
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    fetchedApp = NSWorkspace.shared.frontmostApplication
                    lastDetectedFrontApp = fetchedApp
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 0.1)
                appName = fetchedApp?.localizedName
            }
        }
        metaJson["frontApp"] = appName ?? ""
        logDebug("[FrontAppPlaceholder] Set frontApp in metaJson: \(appName ?? "<none>")")
    }
    // --- END: FrontApp Placeholder Logic ---
    
    if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: action),
                  let fullMatchRange = Range(match.range, in: action) else { continue }
            let key = String(action[keyRange])
            
            // Extract regex replacements if present
            var regexReplacements: [(regex: String, replacement: String)] = []
            if match.numberOfRanges > 3, let replacementRange = Range(match.range(at: 3), in: action) {
                let replacementString = String(action[replacementRange])
                let parts = replacementString.components(separatedBy: "||")
                // Process pairs of regex and replacement
                for i in stride(from: 0, to: parts.count - 1, by: 2) {
                    if i + 1 < parts.count {
                        let regex = parts[i]
                        let replacement = parts[i + 1]
                        regexReplacements.append((regex: regex, replacement: replacement))
                    }
                }
            }
            
            // Check for date placeholder
            if key == "date", match.numberOfRanges > 2, let formatRange = Range(match.range(at: 2), in: action) {
                let format = String(action[formatRange])
                var replacement: String
                switch format {
                case "short":
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .none
                    replacement = formatter.string(from: Date())
                case "long":
                    let formatter = DateFormatter()
                    formatter.dateStyle = .long
                    formatter.timeStyle = .none
                    replacement = formatter.string(from: Date())
                default:
                    // UTS 35 custom format
                    let formatter = DateFormatter()
                    formatter.setLocalizedDateFormatFromTemplate(format)
                    replacement = formatter.string(from: Date())
                }
                
                // Apply regex replacements if any
                replacement = applyRegexReplacements(to: replacement, replacements: regexReplacements)
                
                // Use appropriate escaping based on action type
                let escapedReplacement: String
                switch actionType {
                case .shortcut:
                    escapedReplacement = replacement // No escaping for shortcuts
                case .appleScript:
                    escapedReplacement = escapeAppleScriptString(replacement)
                case .shell, .insert, .url:
                    escapedReplacement = escapeShellCharacters(replacement)
                }
                result.replaceSubrange(fullMatchRange, with: escapedReplacement)
                continue
            }
            // Handle swResult
            else if key == "swResult" {
                var value: String
                if let llm = metaJson["llmResult"] as? String, !llm.isEmpty {
                    value = llm
                } else if let res = metaJson["result"] as? String, !res.isEmpty {
                    value = res
                } else {
                    value = ""
                }
                
                // Apply regex replacements if any
                value = applyRegexReplacements(to: value, replacements: regexReplacements)
                
                // Use appropriate escaping based on action type
                let escapedValue: String
                switch actionType {
                case .shortcut:
                    escapedValue = value // No escaping for shortcuts
                case .appleScript:
                    escapedValue = escapeAppleScriptString(value)
                case .shell, .insert, .url:
                    escapedValue = escapeShellCharacters(value)
                }
                result.replaceSubrange(fullMatchRange, with: escapedValue)
            } else if let jsonValue = metaJson[key] {
                var value: String
                if let stringValue = jsonValue as? String {
                    value = stringValue
                } else if let numberValue = jsonValue as? NSNumber {
                    value = numberValue.stringValue
                } else if let boolValue = jsonValue as? Bool {
                    value = boolValue ? "true" : "false"
                } else if jsonValue is NSNull {
                    value = ""
                } else if let jsonData = try? JSONSerialization.data(withJSONObject: jsonValue),
                          let jsonString = String(data: jsonData, encoding: .utf8) {
                    value = jsonString
                } else {
                    value = String(describing: jsonValue)
                }
                
                // Apply regex replacements if any
                value = applyRegexReplacements(to: value, replacements: regexReplacements)
                
                // Use appropriate escaping based on action type
                let escapedValue: String
                switch actionType {
                case .shortcut:
                    escapedValue = value // No escaping for shortcuts
                case .appleScript:
                    escapedValue = escapeAppleScriptString(value)
                case .shell, .insert, .url:
                    escapedValue = escapeShellCharacters(value)
                }
                result.replaceSubrange(fullMatchRange, with: escapedValue)
            } else {
                // Key doesn't exist in metaJson, remove the placeholder
                result.replaceSubrange(fullMatchRange, with: "")
            }
        }
    }
    return result
}

// MARK: - Regex Replacement Helper

/// Applies multiple regex replacements to a string in sequence
/// - Parameters:
///   - input: The input string to perform replacements on
///   - replacements: Array of tuples containing regex pattern and replacement string
/// - Returns: The string with all regex replacements applied
func applyRegexReplacements(to input: String, replacements: [(regex: String, replacement: String)]) -> String {
    var result = input
    
    for (regexPattern, replacement) in replacements {
        do {
            let regex = try NSRegularExpression(pattern: regexPattern, options: [])
            let range = NSRange(result.startIndex..., in: result)
            let beforeReplace = result
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            logDebug("[RegexReplacement] Pattern: '\(regexPattern)' | Replacement: '\(replacement)' | Before: '\(beforeReplace)' | After: '\(result)'")
        } catch {
            // If regex compilation fails, log the error but continue with other replacements
            logError("[RegexReplacement] Invalid regex pattern '\(regexPattern)': \(error.localizedDescription)")
        }
    }
    
    return result
} 
