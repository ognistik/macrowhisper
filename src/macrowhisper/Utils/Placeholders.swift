import Foundation
import Cocoa

// Function to process LLM result based on XML placeholders in the action
// Supports both {{xml:tagName}} and {{json:xml:tagName}} formats
func processXmlPlaceholders(action: String, llmResult: String) -> (String, [String: String]) {
    var cleanedLlmResult = llmResult
    var extractedTags: [String: String] = [:]
    
    // First, identify which XML tags are requested in the action - supports both {{xml:tag}}, {{json:xml:tag}}, and {{raw:xml:tag}}
    let placeholderPattern = "\\{\\{(?:(json|raw):)?xml:([A-Za-z0-9_]+)\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [.dotMatchesLineSeparators])
    
    var requestedTags: Set<String> = []
    
    // Find all XML placeholders in the action
    if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches {
            if let tagNameRange = Range(match.range(at: 2), in: action) {
                let tagName = String(action[tagNameRange])
                requestedTags.insert(tagName)
            }
        }
    }
    
    // If no XML tags are requested, return the original LLM result
    if requestedTags.isEmpty {
        logDebug("[XMLPlaceholders] No XML placeholders found in action, returning original llmResult unchanged")
        return (cleanedLlmResult, extractedTags)
    }
    
    logDebug("[XMLPlaceholders] Found XML placeholders in action: \(requestedTags)")
    
    // Track if any tags were actually found and removed
    var tagsWereRemoved = false
    
    // For each requested tag, extract content and remove from LLM result
    for tagName in requestedTags {
        logDebug("[XMLPlaceholders] Processing requested tag: '\(tagName)'")
        
        // Pattern to match the specific XML tag (only this exact tag name)
        let tagPattern = "<\(tagName)>(.*?)</\(tagName)>"
        let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.dotMatchesLineSeparators])
        
        // Find ALL occurrences of this specific tag in the LLM result
        if let regex = tagRegex {
            let matches = regex.matches(in: cleanedLlmResult, options: [], range: NSRange(cleanedLlmResult.startIndex..., in: cleanedLlmResult))
            
            if matches.isEmpty {
                logDebug("[XMLPlaceholders] Tag '\(tagName)' not found in llmResult")
                // Store empty content for missing tags
                extractedTags[tagName] = ""
            } else {
                // Process matches in reverse order to avoid index shifting issues
                for match in matches.reversed() {
                    if let contentRange = Range(match.range(at: 1), in: cleanedLlmResult),
                       let fullMatchRange = Range(match.range, in: cleanedLlmResult) {
                        
                        // Extract content and clean it
                        var content = String(cleanedLlmResult[contentRange])
                        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // For multiple occurrences, we'll use the content from the first match found
                        // (which is the last one processed due to reverse order)
                        if extractedTags[tagName] == nil {
                            extractedTags[tagName] = content
                            logDebug("[XMLPlaceholders] Extracted tag '\(tagName)': '\(content)'")
                        }
                        
                        // Remove the XML tag and its content from the result
                        cleanedLlmResult.replaceSubrange(fullMatchRange, with: "")
                        tagsWereRemoved = true
                        logDebug("[XMLPlaceholders] Removed tag '\(tagName)' from llmResult")
                    }
                }
            }
        } else {
            logError("[XMLPlaceholders] Failed to create regex for tag '\(tagName)'")
            extractedTags[tagName] = ""
        }
    }
    
    // Only clean up the LLM result if tags were actually removed
    if tagsWereRemoved {
        // Remove any consecutive empty lines
        cleanedLlmResult = cleanedLlmResult.replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
        
        // Trim leading and trailing whitespace
        cleanedLlmResult = cleanedLlmResult.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    return (cleanedLlmResult, extractedTags)
}

// Function to replace XML placeholders in an action string
// Supports {{xml:tagName}}, {{json:xml:tagName}}, and {{raw:xml:tagName}} formats
// The json: prefix applies JSON string escaping to the extracted XML content
// The raw: prefix applies no escaping to the extracted XML content
func replaceXmlPlaceholders(action: String, extractedTags: [String: String]) -> String {
    var result = action
    
    // Find all XML placeholders using regex - supports {{xml:tag}}, {{json:xml:tag}}, and {{raw:xml:tag}}
    let pattern = "\\{\\{(?:(json|raw):)?xml:([A-Za-z0-9_]+)\\}\\}"
    let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    
    // Get all matches
    if let matches = regex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches.reversed() {
            if let tagNameRange = Range(match.range(at: 2), in: action),
               let fullMatchRange = Range(match.range, in: action) {
                
                let tagName = String(action[tagNameRange])
                
                // Check the prefix type for escaping
                var prefixType: String? = nil
                if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound,
                   let prefixRange = Range(match.range(at: 1), in: action) {
                    prefixType = String(action[prefixRange])
                }
                
                // Replace the placeholder with the extracted content if available and not empty
                if let content = extractedTags[tagName], !content.isEmpty {
                    let finalContent: String
                    switch prefixType {
                    case "json":
                        finalContent = escapeJsonString(content)
                    case "raw":
                        finalContent = content  // No escaping for raw prefix
                    default:
                        finalContent = content  // Default: no escaping
                    }
                    result.replaceSubrange(fullMatchRange, with: finalContent)
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

// MARK: - Time Formatting Helper

/// Formats milliseconds into human-readable time format
/// - Parameter milliseconds: Time value in milliseconds
/// - Returns: Formatted string with appropriate unit (ms, s, or m s)
func formatTimeValue(_ milliseconds: Double) -> String {
    if milliseconds < 1000 {
        // Less than 1 second: show as milliseconds
        return "\(Int(milliseconds))ms"
    } else if milliseconds < 60000 {
        // Less than 1 minute: show as seconds with one decimal
        let seconds = milliseconds / 1000.0
        return String(format: "%.1f", seconds) + "s"
    } else {
        // 1 minute or more: show as minutes and seconds
        let totalSeconds = Int(milliseconds / 1000.0)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        
        if remainingSeconds == 0 {
            return "\(minutes)m"
        } else {
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
}

/// Expands dynamic placeholders in the form {{key}}, {{json:key}}, {{raw:key}}, and {{date:format}} in the action string.
/// The json: prefix applies JSON string escaping to the placeholder value, useful for embedding content in JSON strings.
/// The raw: prefix applies no escaping to the placeholder value, useful for AppleScript and other contexts where escaping breaks functionality.
func processDynamicPlaceholders(action: String, metaJson: [String: Any]) -> String {
    var result = action
    var metaJson = metaJson // Make mutable copy
    
    // Updated regex for {{key}}, {{json:key}}, {{raw:key}}, {{date:...}}, and {{key||regex||replacement}} with multiple replacements
    let placeholderPattern = "\\{\\{(?:(json|raw):)?([A-Za-z0-9_]+)(?::([^|}]+))?(?:\\|\\|(.+?))?\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [.dotMatchesLineSeparators])
    
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
            guard let keyRange = Range(match.range(at: 2), in: action),
                  let fullMatchRange = Range(match.range, in: action) else { continue }
            let key = String(action[keyRange])
            
            // Check the prefix type for escaping
            var prefixType: String? = nil
            if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound,
               let prefixRange = Range(match.range(at: 1), in: action) {
                prefixType = String(action[prefixRange])
            }
            
            // Extract regex replacements if present
            var regexReplacements: [(regex: String, replacement: String)] = []
            if match.numberOfRanges > 4, let replacementRange = Range(match.range(at: 4), in: action) {
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
            if key == "date", match.numberOfRanges > 3, let formatRange = Range(match.range(at: 3), in: action) {
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
                    formatter.dateFormat = format
                    replacement = formatter.string(from: Date())
                }
                
                // Apply regex replacements if any
                replacement = applyRegexReplacements(to: replacement, replacements: regexReplacements)
                
                // Use appropriate escaping based on prefix type
                let escapedReplacement: String
                switch prefixType {
                case "json":
                    escapedReplacement = escapeJsonString(replacement)
                case "raw":
                    escapedReplacement = replacement  // No escaping for raw prefix
                default:
                    escapedReplacement = isAppleScript ? escapeAppleScriptString(replacement) : escapeShellCharacters(replacement)
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
                
                // Check if value is empty - if so, remove the placeholder entirely (including regex replacements)
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Use appropriate escaping based on prefix type or action type
                    let escapedValue: String
                    switch prefixType {
                    case "json":
                        escapedValue = escapeJsonString(value)
                    case "raw":
                        escapedValue = value  // No escaping for raw prefix
                    default:
                        escapedValue = isAppleScript ? escapeAppleScriptString(value) : escapeShellCharacters(value)
                    }
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            } else if let jsonValue = metaJson[key] {
                var value: String
                
                // Handle time-related placeholders: format milliseconds dynamically
                if (key == "duration" || key == "languageModelProcessingTime" || key == "processingTime") {
                    if let numberValue = jsonValue as? NSNumber {
                        let milliseconds = numberValue.doubleValue
                        value = formatTimeValue(milliseconds)
                        logDebug("[TimePlaceholder] Converted \(key) from \(milliseconds)ms to \(value)")
                    } else if let stringValue = jsonValue as? String, let milliseconds = Double(stringValue) {
                        value = formatTimeValue(milliseconds)
                        logDebug("[TimePlaceholder] Converted \(key) from \(milliseconds)ms to \(value)")
                    } else {
                        // Fallback to original value if conversion fails
                        if let stringValue = jsonValue as? String {
                            value = stringValue
                        } else if let numberValue = jsonValue as? NSNumber {
                            value = numberValue.stringValue
                        } else {
                            value = String(describing: jsonValue)
                        }
                        logDebug("[TimePlaceholder] Could not convert \(key), using original value: \(value)")
                    }
                } else {
                    // Standard metaJson value processing
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
                }
                
                // Check if value is empty - if so, remove the placeholder entirely (including regex replacements)
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Use appropriate escaping based on prefix type or action type
                    let escapedValue: String
                    switch prefixType {
                    case "json":
                        escapedValue = escapeJsonString(value)
                    case "raw":
                        escapedValue = value  // No escaping for raw prefix
                    default:
                        escapedValue = isAppleScript ? escapeAppleScriptString(value) : escapeShellCharacters(value)
                    }
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            } else {
                // Key doesn't exist in metaJson, remove the placeholder
                result.replaceSubrange(fullMatchRange, with: "")
            }
        }
    }
    return result
}

/// Expands dynamic placeholders with context-aware escaping based on action type
/// Supports {{key}}, {{json:key}}, {{raw:key}}, {{date:format}}, and regex replacements {{key||regex||replacement}}
/// The json: prefix applies JSON string escaping regardless of action type, useful for embedding content in JSON strings.
/// The raw: prefix applies no escaping regardless of action type, useful for AppleScript and other contexts where escaping breaks functionality.
func processDynamicPlaceholders(action: String, metaJson: [String: Any], actionType: ActionType) -> String {
    var result = action
    var metaJson = metaJson // Make mutable copy
    
    // Updated regex for {{key}}, {{json:key}}, {{raw:key}}, {{date:...}}, and {{key||regex||replacement}} with multiple replacements
    let placeholderPattern = "\\{\\{(?:(json|raw):)?([A-Za-z0-9_]+)(?::([^|}]+))?(?:\\|\\|(.+?))?\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [.dotMatchesLineSeparators])
    
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
            guard let keyRange = Range(match.range(at: 2), in: action),
                  let fullMatchRange = Range(match.range, in: action) else { continue }
            let key = String(action[keyRange])
            
            // Check the prefix type for escaping
            var prefixType: String? = nil
            if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound,
               let prefixRange = Range(match.range(at: 1), in: action) {
                prefixType = String(action[prefixRange])
            }
            
            // Extract regex replacements if present
            var regexReplacements: [(regex: String, replacement: String)] = []
            if match.numberOfRanges > 4, let replacementRange = Range(match.range(at: 4), in: action) {
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
            if key == "date", match.numberOfRanges > 3, let formatRange = Range(match.range(at: 3), in: action) {
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
                    formatter.dateFormat = format
                    replacement = formatter.string(from: Date())
                }
                
                // Apply regex replacements if any
                replacement = applyRegexReplacements(to: replacement, replacements: regexReplacements)
                
                // Use appropriate escaping based on prefix type and action type
                let escapedReplacement: String
                switch prefixType {
                case "json":
                    escapedReplacement = escapeJsonString(replacement)
                case "raw":
                    escapedReplacement = replacement  // No escaping for raw prefix
                default:
                    switch actionType {
                    case .shortcut, .insert:
                        escapedReplacement = replacement // No escaping for shortcuts and insert actions
                    case .appleScript:
                        escapedReplacement = escapeAppleScriptString(replacement)
                    case .shell, .url:
                        escapedReplacement = escapeShellCharacters(replacement)
                    }
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
                
                // Check if value is empty - if so, remove the placeholder entirely (including regex replacements)
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Use appropriate escaping based on prefix type and action type
                    let escapedValue: String
                    switch prefixType {
                    case "json":
                        escapedValue = escapeJsonString(value)
                    case "raw":
                        escapedValue = value  // No escaping for raw prefix
                    default:
                        switch actionType {
                        case .shortcut, .insert:
                            escapedValue = value // No escaping for shortcuts and insert actions
                        case .appleScript:
                            escapedValue = escapeAppleScriptString(value)
                        case .shell, .url:
                            escapedValue = escapeShellCharacters(value)
                        }
                    }
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            } else if let jsonValue = metaJson[key] {
                var value: String
                
                // Handle time-related placeholders: format milliseconds dynamically
                if (key == "duration" || key == "languageModelProcessingTime" || key == "processingTime") {
                    if let numberValue = jsonValue as? NSNumber {
                        let milliseconds = numberValue.doubleValue
                        value = formatTimeValue(milliseconds)
                        logDebug("[TimePlaceholder] Converted \(key) from \(milliseconds)ms to \(value)")
                    } else if let stringValue = jsonValue as? String, let milliseconds = Double(stringValue) {
                        value = formatTimeValue(milliseconds)
                        logDebug("[TimePlaceholder] Converted \(key) from \(milliseconds)ms to \(value)")
                    } else {
                        // Fallback to original value if conversion fails
                        if let stringValue = jsonValue as? String {
                            value = stringValue
                        } else if let numberValue = jsonValue as? NSNumber {
                            value = numberValue.stringValue
                        } else {
                            value = String(describing: jsonValue)
                        }
                        logDebug("[TimePlaceholder] Could not convert \(key), using original value: \(value)")
                    }
                } else {
                    // Standard metaJson value processing
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
                }
                
                // Check if value is empty - if so, remove the placeholder entirely (including regex replacements)
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Use appropriate escaping based on prefix type and action type
                    let escapedValue: String
                    switch prefixType {
                    case "json":
                        escapedValue = escapeJsonString(value)
                    case "raw":
                        escapedValue = value  // No escaping for raw prefix
                    default:
                        switch actionType {
                        case .shortcut, .insert:
                            escapedValue = value // No escaping for shortcuts and insert actions
                        case .appleScript:
                            escapedValue = escapeAppleScriptString(value)
                        case .shell, .url:
                            escapedValue = escapeShellCharacters(value)
                        }
                    }
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
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

// MARK: - Unified Placeholder Processing

/// Processes both XML and dynamic placeholders for any action type
/// This ensures XML placeholders work consistently across all action types (Insert, URL, Shortcut, Shell, AppleScript)
func processAllPlaceholders(action: String, metaJson: [String: Any], actionType: ActionType) -> String {
    logDebug("[UnifiedPlaceholders] Processing placeholders for \(actionType) action")
    var result = action
    var updatedMetaJson = metaJson
    
    // Apply newline conversion for Insert actions only
    // This allows users to type \n in their action templates while preserving literal \n in placeholder content
    if actionType == .insert {
        result = result.replacingOccurrences(of: "\\n", with: "\n")
    }
    
    // First, process XML placeholders if llmResult or result is available
    if let llmResult = metaJson["llmResult"] as? String, !llmResult.isEmpty {
        // logDebug("[UnifiedPlaceholders] Original llmResult: '\(llmResult)'")
        let (cleaned, tags) = processXmlPlaceholders(action: action, llmResult: llmResult)
        // logDebug("[UnifiedPlaceholders] Cleaned llmResult: '\(cleaned)'")
        logDebug("[UnifiedPlaceholders] Extracted tags: \(tags)")
        updatedMetaJson["llmResult"] = cleaned
        result = replaceXmlPlaceholders(action: result, extractedTags: tags)
    } else if let regularResult = metaJson["result"] as? String, !regularResult.isEmpty {
        // logDebug("[UnifiedPlaceholders] Original result: '\(regularResult)'")
        let (_, tags) = processXmlPlaceholders(action: action, llmResult: regularResult)
        logDebug("[UnifiedPlaceholders] Extracted tags: \(tags)")
        result = replaceXmlPlaceholders(action: result, extractedTags: tags)
    }
    
    // Then process dynamic placeholders with appropriate escaping based on action type
    result = processDynamicPlaceholders(action: result, metaJson: updatedMetaJson, actionType: actionType)
    
    // logDebug("[UnifiedPlaceholders] Final processed action: '\(result)'")
    return result
} 
