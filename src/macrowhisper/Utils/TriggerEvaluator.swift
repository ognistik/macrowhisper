import Foundation
import Cocoa

/// Handles trigger evaluation for all action types (inserts, URLs, shortcuts, shell scripts, AppleScript)
class TriggerEvaluator {
    private let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Evaluates triggers for all actions and returns matched actions with their processed results
    func evaluateTriggersForAllActions(
        configManager: ConfigurationManager,
        result: String,
        metaJson: [String: Any],
        frontAppName: String?,
        frontAppBundleId: String?
    ) -> [(action: Any, name: String, type: ActionType, strippedResult: String?)] {
        
        let modeName = metaJson["modeName"] as? String
        var matchedTriggerActions: [(action: Any, name: String, type: ActionType, strippedResult: String?)] = []
        
        // Log evaluation summary at start
        let totalActions = configManager.config.inserts.count + 
                          configManager.config.urls.count + 
                          configManager.config.shortcuts.count + 
                          configManager.config.scriptsShell.count + 
                          configManager.config.scriptsAS.count
        logInfo("[TriggerEval] Evaluating \(totalActions) actions for triggers.")
        
        // Evaluate all inserts for triggers
        for (name, insert) in configManager.config.inserts {
            let insertWithName = InsertWithName(insert: insert, name: name)
            let (matched, strippedResult) = triggersMatch(
                for: insertWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId
            )
            if matched {
                matchedTriggerActions.append((action: insert, name: name, type: .insert, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all URL actions for triggers
        for (name, url) in configManager.config.urls {
            let urlWithName = UrlWithName(url: url, name: name)
            let (matched, strippedResult) = triggersMatch(
                for: urlWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId
            )
            if matched {
                matchedTriggerActions.append((action: url, name: name, type: .url, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all shortcut actions for triggers
        for (name, shortcut) in configManager.config.shortcuts {
            let shortcutWithName = ShortcutWithName(shortcut: shortcut, name: name)
            logDebug("[TriggerEval] Checking shortcut action: name=\(name), triggerVoice=\(shortcut.triggerVoice ?? "nil"), triggerApps=\(shortcut.triggerApps ?? "nil"), triggerModes=\(shortcut.triggerModes ?? "nil"), triggerLogic=\(shortcut.triggerLogic ?? "nil")")
            let (matched, strippedResult) = triggersMatch(
                for: shortcutWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId
            )
            if matched {
                matchedTriggerActions.append((action: shortcut, name: name, type: .shortcut, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all shell script actions for triggers
        for (name, shell) in configManager.config.scriptsShell {
            let shellWithName = ShellWithName(shell: shell, name: name)
            logDebug("[TriggerEval] Checking shell script action: name=\(name), triggerVoice=\(shell.triggerVoice ?? "nil"), triggerApps=\(shell.triggerApps ?? "nil"), triggerModes=\(shell.triggerModes ?? "nil"), triggerLogic=\(shell.triggerLogic ?? "nil")")
            let (matched, strippedResult) = triggersMatch(
                for: shellWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId
            )
            if matched {
                matchedTriggerActions.append((action: shell, name: name, type: .shell, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all AppleScript actions for triggers
        for (name, ascript) in configManager.config.scriptsAS {
            let ascriptWithName = AppleScriptWithName(ascript: ascript, name: name)
            logDebug("[TriggerEval] Checking AppleScript action: name=\(name), triggerVoice=\(ascript.triggerVoice ?? "nil"), triggerApps=\(ascript.triggerApps ?? "nil"), triggerModes=\(ascript.triggerModes ?? "nil"), triggerLogic=\(ascript.triggerLogic ?? "nil")")
            let (matched, strippedResult) = triggersMatch(
                for: ascriptWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId
            )
            if matched {
                matchedTriggerActions.append((action: ascript, name: name, type: .appleScript, strippedResult: strippedResult))
            }
        }
        
        // Log evaluation summary at end
        let matchedNames = matchedTriggerActions.map { $0.name }.joined(separator: ", ")
        if matchedTriggerActions.isEmpty {
            logInfo("[TriggerEval] No actions matched triggers")
        } else {
            logInfo("[TriggerEval] \(matchedTriggerActions.count) action(s) matched triggers: \(matchedNames)")
        }
        
        // Sort actions by name and return
        return matchedTriggerActions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    /// Helper to evaluate triggers for a given action
    private func triggersMatch<T: TriggerProtocol>(
        for action: T,
        result: String,
        modeName: String?,
        frontAppName: String?,
        frontAppBundleId: String?
    ) -> (matched: Bool, strippedResult: String?) {
        
        var voiceMatched = false
        var modeMatched = false
        var appMatched = false
        var strippedResult: String? = nil
        
        let triggerVoice = action.triggerVoice
        let triggerModes = action.triggerModes
        let triggerApps = action.triggerApps
        let triggerLogic = action.triggerLogic
        let actionName = action.name
        
        // Voice trigger
        if let triggerVoice = triggerVoice, !triggerVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let triggers = triggerVoice.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var matched = false
            var exceptionMatched = false
            logDebug("[TriggerEval] Voice trigger check for action '\(actionName)': patterns=\(triggers)")
            
            for trigger in triggers {
                let isException = trigger.hasPrefix("!")
                let actualPattern = isException ? String(trigger.dropFirst()) : trigger
                
                // Check if this is a raw regex pattern (wrapped in =)
                let isRawRegex = actualPattern.hasPrefix("=") && actualPattern.hasSuffix("=")
                let patternToUse: String
                let regexPattern: String
                
                if isRawRegex {
                    // Extract the pattern between = delimiters - this is raw regex
                    let startIndex = actualPattern.index(after: actualPattern.startIndex)
                    let endIndex = actualPattern.index(before: actualPattern.endIndex)
                    patternToUse = String(actualPattern[startIndex..<endIndex])
                    
                    // Check if user has specified case sensitivity
                    if patternToUse.hasPrefix("(?i)") || patternToUse.hasPrefix("(?-i)") {
                        // User has specified case sensitivity, use pattern as-is
                        regexPattern = patternToUse
                    } else {
                        // Default to case-insensitive
                        regexPattern = "(?i)" + patternToUse
                    }
                } else {
                    // For prefix matching (current behavior)
                    patternToUse = actualPattern
                    regexPattern = "^(?i)" + NSRegularExpression.escapedPattern(for: patternToUse)
                }
                
                if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                    let range = NSRange(location: 0, length: result.utf16.count)
                    let found = regex.firstMatch(in: result, options: [], range: range) != nil
                    logDebug("[TriggerEval] Pattern '\(trigger)' (raw regex: \(isRawRegex)) found=\(found) in result.")
                    
                    if isException && found {
                        exceptionMatched = true
                    }
                    if !isException && found {
                        // Strip the trigger from the start, plus any leading punctuation/whitespace after
                        let match = regex.firstMatch(in: result, options: [], range: range)!
                        let afterTriggerIdx = result.index(result.startIndex, offsetBy: match.range.length)
                        var stripped = String(result[afterTriggerIdx...])
                        let punctuationSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
                        while let first = stripped.unicodeScalars.first, punctuationSet.contains(first) {
                            stripped.removeFirst()
                        }
                        if let first = stripped.first {
                            stripped.replaceSubrange(stripped.startIndex...stripped.startIndex, with: String(first).uppercased())
                        }
                        matched = true
                        strippedResult = stripped
                    }
                }
            }
            
            let hasPositive = triggers.contains { !$0.hasPrefix("!") }
            let hasException = triggers.contains { $0.hasPrefix("!") }
            
            if hasPositive {
                voiceMatched = matched && !exceptionMatched
            } else if hasException {
                // Only exceptions: match if no exception matched
                voiceMatched = !exceptionMatched
            } else {
                // No patterns at all (shouldn't happen), treat as matched
                voiceMatched = true
            }
            logDebug("[TriggerEval] Voice trigger result for action '\(actionName)': matched=\(voiceMatched)")
        } else {
            // No voice trigger set, will be handled in final logic determination
            voiceMatched = true
        }
        
        // Mode trigger
        if let triggerModes = triggerModes, !triggerModes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let modeName = modeName {
            let patterns = triggerModes.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var matched = false
            var exceptionMatched = false
            logDebug("[TriggerEval] Mode trigger check for action '\(actionName)': modeName=\"\(modeName)\", patterns=\(patterns)")
            
            for pattern in patterns {
                let isException = pattern.hasPrefix("!")
                let actualPattern = isException ? String(pattern.dropFirst()) : pattern
                let regexPattern: String
                if actualPattern.hasPrefix("(?i)") || actualPattern.hasPrefix("(?-i)") {
                    regexPattern = actualPattern
                } else {
                    regexPattern = "(?i)" + actualPattern
                }
                
                if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                    let range = NSRange(location: 0, length: modeName.utf16.count)
                    let found = regex.firstMatch(in: modeName, options: [], range: range) != nil
                    logDebug("[TriggerEval] Pattern '\(pattern)' found=\(found) in modeName=\(modeName)")
                    
                    if isException && found { exceptionMatched = true }
                    if !isException && found { matched = true }
                }
            }
            
            let hasPositive = patterns.contains { !$0.hasPrefix("!") }
            let hasException = patterns.contains { $0.hasPrefix("!") }
            
            if hasPositive {
                modeMatched = matched && !exceptionMatched
            } else if hasException {
                // Only exceptions: match if no exception matched
                modeMatched = !exceptionMatched
            } else {
                // No patterns at all (shouldn't happen), treat as matched
                modeMatched = true
            }
            logDebug("[TriggerEval] Mode trigger result for action '\(actionName)': matched=\(modeMatched)")
        } else {
            // No mode trigger set, will be handled in final logic determination
            modeMatched = true
        }
        
        // App trigger
        if let triggerApps = triggerApps, !triggerApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let appName = frontAppName, let bundleId = frontAppBundleId {
                let patterns = triggerApps.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var matched = false
                var exceptionMatched = false
                logDebug("[TriggerEval] App trigger check for action '\(actionName)': appName=\"\(appName)\", bundleId=\"\(bundleId)\", patterns=\(patterns)")
                
                for pattern in patterns {
                    let isException = pattern.hasPrefix("!")
                    let actualPattern = isException ? String(pattern.dropFirst()) : pattern
                    let regexPattern: String
                    if actualPattern.hasPrefix("(?i)") || actualPattern.hasPrefix("(?-i)") {
                        regexPattern = actualPattern
                    } else {
                        regexPattern = "(?i)" + actualPattern
                    }
                    
                    if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                        let nameRange = NSRange(location: 0, length: appName.utf16.count)
                        let bundleRange = NSRange(location: 0, length: bundleId.utf16.count)
                        let found = regex.firstMatch(in: appName, options: [], range: nameRange) != nil || 
                                   regex.firstMatch(in: bundleId, options: [], range: bundleRange) != nil
                        logDebug("[TriggerEval] Pattern '\(pattern)' found=\(found) in appName=\(appName), bundleId=\(bundleId)")
                        
                        if isException && found { exceptionMatched = true }
                        if !isException && found { matched = true }
                    }
                }
                
                // After evaluating all patterns, determine match logic for app triggers
                let hasPositive = patterns.contains { !$0.hasPrefix("!") }
                let hasException = patterns.contains { $0.hasPrefix("!") }
                
                if hasPositive {
                    appMatched = matched && !exceptionMatched
                } else if hasException {
                    // Only exceptions: match if no exception matched
                    appMatched = !exceptionMatched
                } else {
                    // No patterns at all (shouldn't happen), treat as matched
                    appMatched = true
                }
                logDebug("[TriggerEval] App trigger result for action '\(actionName)': matched=\(appMatched)")
            } else {
                logDebug("[TriggerEval] App trigger set for action '\(actionName)' but appName or bundleId is nil. Not matching.")
                appMatched = false
            }
        } else {
            // No app trigger set, will be handled in final logic determination
            appMatched = true
        }
        
        // Determine logic
        let logic = (triggerLogic ?? "or").lowercased()
        
        // Check which triggers are actually set (not empty)
        let voiceTriggerSet = triggerVoice != nil && !triggerVoice!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modeTriggerSet = triggerModes != nil && !triggerModes!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appTriggerSet = triggerApps != nil && !triggerApps!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if logic == "and" {
            // AND logic: all set triggers must match
            // If no triggers are set at all, don't match
            if !voiceTriggerSet && !modeTriggerSet && !appTriggerSet {
                return (false, strippedResult)
            }
            
            // All set triggers must match
            var allMatch = true
            if voiceTriggerSet && !voiceMatched { allMatch = false }
            if modeTriggerSet && !modeMatched { allMatch = false }
            if appTriggerSet && !appMatched { allMatch = false }
            
            return (allMatch, strippedResult)
        } else {
            // OR logic: only non-empty triggers are considered
            var anyMatch = false
            if voiceTriggerSet && voiceMatched { anyMatch = true }
            if modeTriggerSet && modeMatched { anyMatch = true }
            if appTriggerSet && appMatched { anyMatch = true }
            
            return (anyMatch, strippedResult)
        }
    }
}

// MARK: - Supporting Types and Protocols

enum ActionType {
    case insert
    case url
    case shortcut
    case shell
    case appleScript
}

protocol TriggerProtocol {
    var triggerVoice: String? { get }
    var triggerApps: String? { get }
    var triggerModes: String? { get }
    var triggerLogic: String? { get }
    var name: String { get }
}

// Wrapper structs to add name property to existing types
struct InsertWithName: TriggerProtocol {
    let insert: AppConfiguration.Insert
    let name: String
    
    var triggerVoice: String? { insert.triggerVoice }
    var triggerApps: String? { insert.triggerApps }
    var triggerModes: String? { insert.triggerModes }
    var triggerLogic: String? { insert.triggerLogic }
}

struct UrlWithName: TriggerProtocol {
    let url: AppConfiguration.Url
    let name: String
    
    var triggerVoice: String? { url.triggerVoice }
    var triggerApps: String? { url.triggerApps }
    var triggerModes: String? { url.triggerModes }
    var triggerLogic: String? { url.triggerLogic }
}

struct ShortcutWithName: TriggerProtocol {
    let shortcut: AppConfiguration.Shortcut
    let name: String
    
    var triggerVoice: String? { shortcut.triggerVoice }
    var triggerApps: String? { shortcut.triggerApps }
    var triggerModes: String? { shortcut.triggerModes }
    var triggerLogic: String? { shortcut.triggerLogic }
}

struct ShellWithName: TriggerProtocol {
    let shell: AppConfiguration.ScriptShell
    let name: String
    
    var triggerVoice: String? { shell.triggerVoice }
    var triggerApps: String? { shell.triggerApps }
    var triggerModes: String? { shell.triggerModes }
    var triggerLogic: String? { shell.triggerLogic }
}

struct AppleScriptWithName: TriggerProtocol {
    let ascript: AppConfiguration.ScriptAppleScript
    let name: String
    
    var triggerVoice: String? { ascript.triggerVoice }
    var triggerApps: String? { ascript.triggerApps }
    var triggerModes: String? { ascript.triggerModes }
    var triggerLogic: String? { ascript.triggerLogic }
} 
