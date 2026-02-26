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
                            logDebug("[XMLPlaceholders] Extracted tag '\(tagName)': \(redactForLogs(content))")
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
// The actionType parameter determines additional escaping for specific action types (e.g., URL encoding for URL actions)
func replaceXmlPlaceholders(action: String, extractedTags: [String: String], actionType: ActionType? = nil) -> String {
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
                        // Apply action-specific escaping if no prefix is specified
                        if let actionType = actionType {
                            finalContent = applyFinalEscaping(value: content, prefixType: nil, actionType: actionType)
                        } else {
                            finalContent = content  // Default: no escaping when actionType is nil
                        }
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

/// Resolves a potentially nested key path (dot notation) from metaJson.
/// Supports object traversal (e.g. promptContext.systemContext.language)
/// and array indexes (e.g. segments.0.text).
func resolveMetaJsonValue(for keyPath: String, in metaJson: [String: Any]) -> Any? {
    let pathComponents = keyPath.split(separator: ".").map(String.init)
    guard !pathComponents.isEmpty else { return nil }
    
    var current: Any = metaJson
    for component in pathComponents {
        if let dict = current as? [String: Any] {
            guard let next = dict[component] else { return nil }
            current = next
            continue
        }
        
        if let array = current as? [Any], let index = Int(component), index >= 0, index < array.count {
            current = array[index]
            continue
        }
        
        return nil
    }
    
    return current
}

/// Renders segments array in a human-readable format.
/// Speaker labels are included only when speaker metadata indicates diarization.
func formatSegmentsForPlaceholder(_ segmentsValue: Any, speakersValue: Any?) -> String? {
    guard let segments = segmentsValue as? [[String: Any]], !segments.isEmpty else { return nil }
    
    let hasExplicitSpeakers = ((speakersValue as? [Any])?.isEmpty == false)
    let hasSegmentSpeakerIdsBeyondZero = segments.contains { segment in
        if let speakerInt = segment["speaker"] as? Int {
            return speakerInt > 0
        }
        if let speakerNumber = segment["speaker"] as? NSNumber {
            return speakerNumber.intValue > 0
        }
        return false
    }
    let shouldShowSpeakers = hasExplicitSpeakers || hasSegmentSpeakerIdsBeyondZero
    
    // Helper: avoid spaces before punctuation when reconstructing text.
    func appendToken(_ token: String, to current: inout String) {
        if current.isEmpty {
            current = token
            return
        }
        let noLeadingSpaceChars = CharacterSet(charactersIn: ".,!?;:)]}%\"'")
        if let firstScalar = token.unicodeScalars.first, noLeadingSpaceChars.contains(firstScalar) {
            current += token
        } else {
            current += " " + token
        }
    }
    
    func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(floor(seconds)))
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    if shouldShowSpeakers {
        struct SegmentBlock {
            let speaker: Int?
            let start: Double
            var text: String
        }
        
        let shouldShiftSpeakerNumbers = segments.contains { segment in
            if let speakerInt = segment["speaker"] as? Int {
                return speakerInt == 0
            }
            if let speakerNumber = segment["speaker"] as? NSNumber {
                return speakerNumber.intValue == 0
            }
            return false
        }
        
        var blocks: [SegmentBlock] = []
        blocks.reserveCapacity(16)
        
        for segment in segments {
            let token = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                continue
            }
            
            let speaker: Int?
            if let speakerInt = segment["speaker"] as? Int {
                speaker = speakerInt
            } else if let speakerNumber = segment["speaker"] as? NSNumber {
                speaker = speakerNumber.intValue
            } else {
                speaker = nil
            }
            
            let start: Double
            if let startDouble = segment["start"] as? Double {
                start = startDouble
            } else if let startNumber = segment["start"] as? NSNumber {
                start = startNumber.doubleValue
            } else {
                start = 0
            }
            
            if let lastIndex = blocks.indices.last, blocks[lastIndex].speaker == speaker {
                var updated = blocks[lastIndex]
                appendToken(token, to: &updated.text)
                blocks[lastIndex] = updated
            } else {
                blocks.append(SegmentBlock(speaker: speaker, start: start, text: token))
            }
        }
        
        if blocks.isEmpty {
            return nil
        }
        
        let renderedBlocks = blocks.map { block -> String in
            let header: String
            if let speaker = block.speaker, speaker >= 0 {
                let displaySpeaker = shouldShiftSpeakerNumbers ? (speaker + 1) : speaker
                header = "\(formatTimestamp(block.start)) Speaker \(displaySpeaker)"
            } else {
                header = "\(formatTimestamp(block.start))"
            }
            return "\(header)\n\(block.text)"
        }
        
        return renderedBlocks.joined(separator: "\n\n")
    }
    
    // Non-diarized fallback: merge all segments into a single readable paragraph.
    var mergedText = ""
    for segment in segments {
        let token = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            continue
        }
        appendToken(token, to: &mergedText)
    }
    
    if mergedText.isEmpty {
        return nil
    }
    
    return mergedText
}

/// Converts resolved metadata values into placeholder strings with special handling for known structures.
func stringifyPlaceholderValue(for keyPath: String, jsonValue: Any, metaJson: [String: Any]) -> String {
    let keyName = keyPath.split(separator: ".").last.map(String.init) ?? keyPath
    
    // Handle time-related placeholders: format milliseconds dynamically
    if keyName == "duration" || keyName == "languageModelProcessingTime" || keyName == "processingTime" {
        if let numberValue = jsonValue as? NSNumber {
            let milliseconds = numberValue.doubleValue
            let formatted = formatTimeValue(milliseconds)
            logDebug("[TimePlaceholder] Converted \(keyPath) from \(milliseconds)ms to \(formatted)")
            return formatted
        } else if let stringValue = jsonValue as? String, let milliseconds = Double(stringValue) {
            let formatted = formatTimeValue(milliseconds)
            logDebug("[TimePlaceholder] Converted \(keyPath) from \(milliseconds)ms to \(formatted)")
            return formatted
        }
    }
    
    // Render segments as a readable transcript instead of raw JSON.
    if keyName == "segments",
       let formattedSegments = formatSegmentsForPlaceholder(jsonValue, speakersValue: metaJson["speakers"]),
       !formattedSegments.isEmpty {
        return formattedSegments
    }
    
    if let stringValue = jsonValue as? String {
        return stringValue
    }
    if let numberValue = jsonValue as? NSNumber {
        return numberValue.stringValue
    }
    if let boolValue = jsonValue as? Bool {
        return boolValue ? "true" : "false"
    }
    if jsonValue is NSNull {
        return ""
    }
    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonValue),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        return jsonString
    }
    
    return String(describing: jsonValue)
}

/// Expands dynamic placeholders with context-aware escaping based on action type
/// Supports {{key}}, {{json:key}}, {{raw:key}}, {{date:format}}, and regex replacements {{key||regex||replacement}}
/// The json: prefix applies JSON string escaping regardless of action type, useful for embedding content in JSON strings.
/// The raw: prefix applies no escaping regardless of action type, useful for AppleScript and other contexts where escaping breaks functionality.
/// For URL actions, URL encoding is deferred until after all regex replacements to prevent double encoding.
func processDynamicPlaceholders(action: String, metaJson: [String: Any], actionType: ActionType) -> String {
    var result = action
    
    // Updated regex for {{key}}, {{json:key}}, {{raw:key}}, {{date:...}}, and {{key||regex||replacement}} with multiple replacements
    let placeholderPattern = "\\{\\{(?:(json|raw):)?([A-Za-z0-9_.]+)(?::([^|}]+))?(?:\\|\\|(.+?))?\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [.dotMatchesLineSeparators])
    
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
                
                // Apply final escaping after all regex replacements are complete
                let escapedReplacement = applyFinalEscaping(value: replacement, prefixType: prefixType, actionType: actionType)
                result.replaceSubrange(fullMatchRange, with: escapedReplacement)
                continue
            }
            
            // Handle selectedText
            else if key == "selectedText" {
                var value = (metaJson["selectedText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !value.isEmpty {
                    logDebug("[SelectedTextPlaceholder] Using selected text from metaJson session snapshot")
                }

                if value.isEmpty, let watcher = recordingsWatcher, watcher.hasActiveRecordingSessions() {
                    value = watcher.getClipboardMonitor().getActiveSessionSelectedText()
                    if !value.isEmpty {
                        logDebug("[SelectedTextPlaceholder] Using selected text from active recording session")
                    }
                }

                if value.isEmpty {
                    value = getSelectedText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        logDebug("[SelectedTextPlaceholder] Captured selected text at placeholder execution time")
                    }
                }
                
                // Check if value is empty - if so, remove the placeholder entirely
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            }
            
            // Handle appContext (captured during placeholder processing if placeholder is present)
            else if key == "appContext" {
                var value = (metaJson["appContext"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if value.isEmpty {
                    value = getAppContext(
                        targetPid: extractFrontAppPid(from: metaJson),
                        fallbackAppName: (metaJson["frontAppName"] as? String) ?? (metaJson["frontApp"] as? String)
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // Check if value is empty - if so, remove the placeholder entirely
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            }

            // Handle appVocabulary (captured lazily at placeholder time from front app accessibility content)
            else if key == "appVocabulary" {
                var value = (metaJson["appVocabulary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if value.isEmpty {
                    value = getAppVocabulary(
                        targetPid: extractFrontAppPid(from: metaJson),
                        fallbackAppName: (metaJson["frontAppName"] as? String) ?? (metaJson["frontApp"] as? String),
                        fallbackBundleId: metaJson["frontAppBundleId"] as? String
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Check if value is empty - if so, remove the placeholder entirely
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)

                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            }

            // Handle frontApp (captured lazily at placeholder execution time)
            else if key == "frontApp" {
                var value = ((metaJson["frontApp"] as? String) ?? (metaJson["frontAppName"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    value = getCurrentFrontAppName().trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Check if value is empty - if so, remove the placeholder entirely
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)

                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            }
            
            // Handle clipboardContext
            else if key == "clipboardContext" {
                var value = (metaJson["clipboardContext"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let enableStacking = (metaJson["clipboardStacking"] as? Bool)
                    ?? globalConfigManager?.config.defaults.clipboardStacking
                    ?? false

                if !value.isEmpty {
                    logDebug("[ClipboardContextPlaceholder] Using clipboard context from metaJson session snapshot")
                }

                if value.isEmpty, let watcher = recordingsWatcher {
                    let clipboardMonitor = watcher.getClipboardMonitor()

                    if watcher.hasActiveRecordingSessions() {
                        value = clipboardMonitor.getActiveSessionClipboardContentWithStacking(enableStacking: enableStacking)
                        if !value.isEmpty {
                            logDebug("[ClipboardContextPlaceholder] Using clipboard context from active recording session")
                        }
                    }

                    if value.isEmpty {
                        if enableStacking {
                            value = getRecentClipboardContentForCLIWithStacking(enableStacking: true).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !value.isEmpty {
                                logDebug("[ClipboardContextPlaceholder] Using recent clipboard content with stacking from global history")
                            }
                        } else {
                            value = getRecentClipboardContentForCLI().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !value.isEmpty {
                                logDebug("[ClipboardContextPlaceholder] Using recent clipboard content from global history")
                            }
                        }
                    }
                }
                
                // Check if value is empty - if so, remove the placeholder entirely
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
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
                    
                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
                    result.replaceSubrange(fullMatchRange, with: escapedValue)
                }
            } else if let jsonValue = resolveMetaJsonValue(for: key, in: metaJson) {
                var value = stringifyPlaceholderValue(for: key, jsonValue: jsonValue, metaJson: metaJson)
                
                // Check if value is empty - if so, remove the placeholder entirely (including regex replacements)
                if value.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: "")
                } else {
                    // Apply regex replacements only if value is not empty
                    value = applyRegexReplacements(to: value, replacements: regexReplacements)
                    
                    // Apply final escaping after all regex replacements are complete
                    let escapedValue = applyFinalEscaping(value: value, prefixType: prefixType, actionType: actionType)
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

private func getCurrentFrontAppName() -> String {
    if Thread.isMainThread {
        let frontApp = NSWorkspace.shared.frontmostApplication
        globalState.lastDetectedFrontApp = frontApp
        return frontApp?.localizedName ?? ""
    }

    var fetchedApp: NSRunningApplication?
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        fetchedApp = NSWorkspace.shared.frontmostApplication
        globalState.lastDetectedFrontApp = fetchedApp
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 0.1)
    return fetchedApp?.localizedName ?? ""
}

private func extractFrontAppPid(from metaJson: [String: Any]) -> Int32? {
    if let value = metaJson["frontAppPid"] as? Int32 {
        return value
    }
    if let value = metaJson["frontAppPid"] as? Int {
        return Int32(value)
    }
    if let value = metaJson["frontAppPid"] as? NSNumber {
        return Int32(value.intValue)
    }
    if let value = metaJson["frontAppPid"] as? String, let parsed = Int(value) {
        return Int32(parsed)
    }
    return nil
}

// MARK: - URL-Specific Escaping Helper

/// Applies appropriate escaping for URL actions, ensuring encoding happens only once after all regex replacements
/// - Parameters:
///   - value: The final value after all regex replacements
///   - prefixType: The prefix type (json, raw, or nil)
///   - actionType: The action type for context-aware escaping
/// - Returns: The properly escaped value
func applyFinalEscaping(value: String, prefixType: String?, actionType: ActionType) -> String {
    switch prefixType {
    case "json":
        return escapeJsonString(value)
    case "raw":
        return value  // No escaping for raw prefix
    default:
        switch actionType {
        case .shortcut, .insert:
            return value // No escaping for shortcuts and insert actions
        case .appleScript:
            return escapeAppleScriptString(value)
        case .shell:
            return escapeShellCharacters(value)
        case .url:
            // URL-encode only the final value after all regex replacements
            return escapeUrlPlaceholder(value)
        }
    }
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
            logDebug("[RegexReplacement] Pattern: \(redactForLogs(regexPattern)) | Replacement: \(redactForLogs(replacement)) | Before: \(redactForLogs(beforeReplace)) | After: \(redactForLogs(result))")
        } catch {
            // If regex compilation fails, log the error but continue with other replacements
            logError("[RegexReplacement] Invalid regex pattern \(redactForLogs(regexPattern)): \(error.localizedDescription)")
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
        if redactedLogsEnabled {
            logDebug("[UnifiedPlaceholders] Extracted tags: [REDACTED count=\(tags.count)]")
        } else {
            logDebug("[UnifiedPlaceholders] Extracted tags: \(tags)")
        }
        updatedMetaJson["llmResult"] = cleaned
        result = replaceXmlPlaceholders(action: result, extractedTags: tags, actionType: actionType)
    } else if let regularResult = metaJson["result"] as? String, !regularResult.isEmpty {
        // logDebug("[UnifiedPlaceholders] Original result: '\(regularResult)'")
        let (_, tags) = processXmlPlaceholders(action: action, llmResult: regularResult)
        if redactedLogsEnabled {
            logDebug("[UnifiedPlaceholders] Extracted tags: [REDACTED count=\(tags.count)]")
        } else {
            logDebug("[UnifiedPlaceholders] Extracted tags: \(tags)")
        }
        result = replaceXmlPlaceholders(action: result, extractedTags: tags, actionType: actionType)
    }
    
    // Then process dynamic placeholders with appropriate escaping based on action type
    result = processDynamicPlaceholders(action: result, metaJson: updatedMetaJson, actionType: actionType)
    
    // logDebug("[UnifiedPlaceholders] Final processed action: '\(result)'")
    return result
}

// MARK: - CLI Clipboard Helper

/// Gets recent clipboard content for CLI execution context using the existing ClipboardMonitor
/// This avoids creating duplicate clipboard monitoring instances
func getRecentClipboardContentForCLI() -> String {
    // Use the existing ClipboardMonitor from RecordingsFolderWatcher if available
    if let watcher = recordingsWatcher {
        let clipboardMonitor = watcher.getClipboardMonitor()
        return clipboardMonitor.getRecentClipboardContent()
    }
    
    // Fallback: if no watcher is available, return empty string
    logDebug("[ClipboardContextPlaceholder] No RecordingsFolderWatcher available for CLI clipboard access")
    return ""
}

/// Gets recent clipboard content for CLI execution context with stacking support
/// This avoids creating duplicate clipboard monitoring instances
/// - Parameter enableStacking: Whether to enable clipboard stacking (from configuration)
/// - Returns: Formatted clipboard content (single content or XML-tagged stack)
func getRecentClipboardContentForCLIWithStacking(enableStacking: Bool) -> String {
    // Use the existing ClipboardMonitor from RecordingsFolderWatcher if available
    if let watcher = recordingsWatcher {
        let clipboardMonitor = watcher.getClipboardMonitor()
        return clipboardMonitor.getRecentClipboardContentWithStacking(enableStacking: enableStacking)
    }
    
    // Fallback: if no watcher is available, return empty string
    logDebug("[ClipboardContextPlaceholder] No RecordingsFolderWatcher available for CLI clipboard access")
    return ""
} 
