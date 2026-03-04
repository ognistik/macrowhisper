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
        frontAppBundleId: String?,
        frontAppUrl: String?
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
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking insert action: name=\(name), triggerVoice=\(summarizeForLogs(insert.triggerVoice)), triggerApps=\(summarizeForLogs(insert.triggerApps)), triggerModes=\(summarizeForLogs(insert.triggerModes)), triggerUrls=\(summarizeForLogs(insert.triggerUrls)), triggerLogic=\(insert.triggerLogic ?? "nil")")
            }
            let (matched, strippedResult) = triggersMatch(
                for: insertWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if matched {
                matchedTriggerActions.append((action: insert, name: name, type: .insert, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all URL actions for triggers
        for (name, url) in configManager.config.urls {
            let urlWithName = UrlWithName(url: url, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking URL action: name=\(name), triggerVoice=\(summarizeForLogs(url.triggerVoice)), triggerApps=\(summarizeForLogs(url.triggerApps)), triggerModes=\(summarizeForLogs(url.triggerModes)), triggerUrls=\(summarizeForLogs(url.triggerUrls)), triggerLogic=\(url.triggerLogic ?? "nil")")
            }
            let (matched, strippedResult) = triggersMatch(
                for: urlWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if matched {
                matchedTriggerActions.append((action: url, name: name, type: .url, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all shortcut actions for triggers
        for (name, shortcut) in configManager.config.shortcuts {
            let shortcutWithName = ShortcutWithName(shortcut: shortcut, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking shortcut action: name=\(name), triggerVoice=\(summarizeForLogs(shortcut.triggerVoice)), triggerApps=\(summarizeForLogs(shortcut.triggerApps)), triggerModes=\(summarizeForLogs(shortcut.triggerModes)), triggerUrls=\(summarizeForLogs(shortcut.triggerUrls)), triggerLogic=\(shortcut.triggerLogic ?? "nil")")
            }
            let (matched, strippedResult) = triggersMatch(
                for: shortcutWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if matched {
                matchedTriggerActions.append((action: shortcut, name: name, type: .shortcut, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all shell script actions for triggers
        for (name, shell) in configManager.config.scriptsShell {
            let shellWithName = ShellWithName(shell: shell, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking shell script action: name=\(name), triggerVoice=\(summarizeForLogs(shell.triggerVoice)), triggerApps=\(summarizeForLogs(shell.triggerApps)), triggerModes=\(summarizeForLogs(shell.triggerModes)), triggerUrls=\(summarizeForLogs(shell.triggerUrls)), triggerLogic=\(shell.triggerLogic ?? "nil")")
            }
            let (matched, strippedResult) = triggersMatch(
                for: shellWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if matched {
                matchedTriggerActions.append((action: shell, name: name, type: .shell, strippedResult: strippedResult))
            }
        }
        
        // Evaluate all AppleScript actions for triggers
        for (name, ascript) in configManager.config.scriptsAS {
            let ascriptWithName = AppleScriptWithName(ascript: ascript, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking AppleScript action: name=\(name), triggerVoice=\(summarizeForLogs(ascript.triggerVoice)), triggerApps=\(summarizeForLogs(ascript.triggerApps)), triggerModes=\(summarizeForLogs(ascript.triggerModes)), triggerUrls=\(summarizeForLogs(ascript.triggerUrls)), triggerLogic=\(ascript.triggerLogic ?? "nil")")
            }
            let (matched, strippedResult) = triggersMatch(
                for: ascriptWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
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
        frontAppBundleId: String?,
        frontAppUrl: String?
    ) -> (matched: Bool, strippedResult: String?) {
        let verbose = isVerboseLogDetailEnabled()
        var voiceMatched = false
        var modeMatched = false
        var appMatched = false
        var urlMatched = false
        var strippedResult: String? = nil
        
        let triggerVoice = action.triggerVoice
        let triggerModes = action.triggerModes
        let triggerApps = action.triggerApps
        let triggerUrls = action.triggerUrls
        let triggerLogic = action.triggerLogic
        let actionName = action.name
        
        // Voice trigger
        if let triggerVoice = triggerVoice, !triggerVoice
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            // Split triggers by '|' but ignore '|' inside raw regex blocks delimited by '=='
            let triggers = splitVoiceTriggers(triggerVoice)
            var matched = false
            var exceptionMatched = false
            if verbose {
                if redactedLogsEnabled {
                    logDebug("[TriggerEval] Voice trigger check for action '\(actionName)': patterns=[REDACTED count=\(triggers.count)]")
                } else {
                    logDebug("[TriggerEval] Voice trigger check for action '\(actionName)': patterns=\(triggers)")
                }
            }
            
            for trigger in triggers {
                let isException = trigger.hasPrefix("!")
                let actualPattern = isException ? String(trigger.dropFirst()) : trigger
                
                // Check if this is a raw regex pattern (wrapped in ==)
                let isRawRegex = actualPattern.hasPrefix("==") && actualPattern.hasSuffix("==")
                let patternToUse: String
                let regexPattern: String
                
                if isRawRegex {
                    // Extract the pattern between '==' delimiters - this is raw regex
                    let startIndex = actualPattern.index(actualPattern.startIndex, offsetBy: 2)
                    let endIndex = actualPattern.index(actualPattern.endIndex, offsetBy: -2)
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
                    if verbose || found {
                        logDebug(
                            "[TriggerEval] Voice pattern \(summarizeForLogs(trigger, maxPreview: 80)) " +
                            "(raw regex: \(isRawRegex)) found=\(found) " +
                            "input=\(summarizeForLogs(result, maxPreview: 120)) " +
                            "regex=\(summarizeForLogs(regexPattern, maxPreview: 120))"
                        )
                    }
                    
                    if isException && found {
                        exceptionMatched = true
                    }
                    if !isException && found {
                        matched = true
                        if !isRawRegex {
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
                            strippedResult = stripped
                        }
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
            if verbose || voiceMatched {
                logDebug("[TriggerEval] Voice trigger result for action '\(actionName)': matched=\(voiceMatched)")
            }
        } else {
            // No voice trigger set, will be handled in final logic determination
            voiceMatched = true
        }
        
        // Mode trigger
        if let triggerModes = triggerModes, !triggerModes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let modeName = modeName {
            let patterns = triggerModes.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var matched = false
            var exceptionMatched = false
            if verbose {
                if redactedLogsEnabled {
                    logDebug("[TriggerEval] Mode trigger check for action '\(actionName)': modeName=\(summarizeForLogs(modeName)), patterns=[REDACTED count=\(patterns.count)]")
                } else {
                    logDebug("[TriggerEval] Mode trigger check for action '\(actionName)': modeName=\"\(modeName)\", patterns=\(patterns)")
                }
            }
            
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
                    if verbose || found {
                        logDebug(
                            "[TriggerEval] Mode pattern \(summarizeForLogs(pattern, maxPreview: 80)) " +
                            "found=\(found) modeName=\(summarizeForLogs(modeName, maxPreview: 80))"
                        )
                    }
                    
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
            if verbose || modeMatched {
                logDebug("[TriggerEval] Mode trigger result for action '\(actionName)': matched=\(modeMatched)")
            }
        } else {
            // No mode trigger set, will be handled in final logic determination
            modeMatched = true
        }
        
        // App trigger
        if let triggerApps = triggerApps, !triggerApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if frontAppName == nil && frontAppBundleId == nil {
                if verbose {
                    logDebug("[TriggerEval] App trigger set for action '\(actionName)' but both appName and bundleId are nil. Not matching.")
                }
                appMatched = false
            } else {
                let appName = frontAppName ?? ""
                let bundleId = frontAppBundleId ?? ""
                let patterns = triggerApps.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var matched = false
                var exceptionMatched = false
                if verbose {
                    if redactedLogsEnabled {
                        logDebug("[TriggerEval] App trigger check for action '\(actionName)': appName=\(summarizeForLogs(appName)), bundleId=\(summarizeForLogs(bundleId)), patterns=[REDACTED count=\(patterns.count)]")
                    } else {
                        logDebug("[TriggerEval] App trigger check for action '\(actionName)': appName=\"\(appName)\", bundleId=\"\(bundleId)\", patterns=\(patterns)")
                    }
                }
                
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
                        let foundInName: Bool
                        if frontAppName != nil {
                            let nameRange = NSRange(location: 0, length: appName.utf16.count)
                            foundInName = regex.firstMatch(in: appName, options: [], range: nameRange) != nil
                        } else {
                            foundInName = false
                        }
                        let foundInBundle: Bool
                        if frontAppBundleId != nil {
                            let bundleRange = NSRange(location: 0, length: bundleId.utf16.count)
                            foundInBundle = regex.firstMatch(in: bundleId, options: [], range: bundleRange) != nil
                        } else {
                            foundInBundle = false
                        }
                        let found = foundInName || foundInBundle
                        if verbose || found {
                            logDebug(
                                "[TriggerEval] App pattern \(summarizeForLogs(pattern, maxPreview: 80)) found=\(found) " +
                                "appName=\(summarizeForLogs(appName, maxPreview: 80)) bundleId=\(summarizeForLogs(bundleId, maxPreview: 80))"
                            )
                        }
                        
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
                if verbose || appMatched {
                    logDebug("[TriggerEval] App trigger result for action '\(actionName)': matched=\(appMatched)")
                }
            }
        } else {
            // No app trigger set, will be handled in final logic determination
            appMatched = true
        }

        // URL trigger
        if let triggerUrls = triggerUrls, !triggerUrls.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let patterns = triggerUrls
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if patterns.isEmpty {
                if verbose {
                    logDebug("[TriggerEval] URL trigger set for action '\(actionName)' but all tokens are empty. Not matching.")
                }
                urlMatched = false
            } else if frontAppUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                if verbose {
                    logDebug("[TriggerEval] URL trigger set for action '\(actionName)' but frontAppUrl is empty. Not matching.")
                }
                urlMatched = false
            } else if let rawCandidateUrl = frontAppUrl, let candidate = parseUrlTriggerCandidate(from: rawCandidateUrl) {
                var matched = false
                var exceptionMatched = false
                var validPatternCount = 0

                if verbose {
                    if redactedLogsEnabled {
                        logDebug("[TriggerEval] URL trigger check for action '\(actionName)': candidate=\(summarizeForLogs(rawCandidateUrl, maxPreview: 120)), patterns=[REDACTED count=\(patterns.count)]")
                    } else {
                        logDebug("[TriggerEval] URL trigger check for action '\(actionName)': candidate=\"\(rawCandidateUrl)\", patterns=\(patterns)")
                    }
                }

                for pattern in patterns {
                    let isException = pattern.hasPrefix("!")
                    let actualPattern = isException ? String(pattern.dropFirst()) : pattern

                    guard let parsedPattern = parseUrlTriggerPattern(from: actualPattern) else {
                        logDebug("[TriggerEval] Invalid URL trigger pattern skipped for action '\(actionName)': \(summarizeForLogs(actualPattern, maxPreview: 120))")
                        continue
                    }

                    validPatternCount += 1
                    let found = urlTriggerPatternMatches(parsedPattern, candidate: candidate)
                    if verbose || found {
                        logDebug(
                            "[TriggerEval] URL pattern \(summarizeForLogs(pattern, maxPreview: 120)) found=\(found) " +
                            "candidate=\(summarizeForLogs(rawCandidateUrl, maxPreview: 120))"
                        )
                    }

                    if isException && found { exceptionMatched = true }
                    if !isException && found { matched = true }
                }

                if validPatternCount == 0 {
                    urlMatched = false
                } else {
                    let hasPositive = patterns.contains { !$0.hasPrefix("!") }
                    let hasException = patterns.contains { $0.hasPrefix("!") }

                    if hasPositive {
                        urlMatched = matched && !exceptionMatched
                    } else if hasException {
                        urlMatched = !exceptionMatched
                    } else {
                        urlMatched = false
                    }
                }

                if verbose || urlMatched {
                    logDebug("[TriggerEval] URL trigger result for action '\(actionName)': matched=\(urlMatched)")
                }
            } else {
                if verbose {
                    logDebug("[TriggerEval] URL trigger set for action '\(actionName)' but frontAppUrl is not parseable. Not matching.")
                }
                urlMatched = false
            }
        } else {
            // No URL trigger set, will be handled in final logic determination
            urlMatched = true
        }
        
        // Determine logic
        let logic = (triggerLogic ?? "or").lowercased()
        
        // Check which triggers are actually set (not empty)
        let voiceTriggerSet = triggerVoice != nil && !triggerVoice!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modeTriggerSet = triggerModes != nil && !triggerModes!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appTriggerSet = triggerApps != nil && !triggerApps!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlTriggerSet = triggerUrls != nil && !triggerUrls!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        let finalMatched: Bool
        if logic == "and" {
            // AND logic: all set triggers must match
            // If no triggers are set at all, don't match
            if !voiceTriggerSet && !modeTriggerSet && !appTriggerSet && !urlTriggerSet {
                finalMatched = false
            } else {
                // All set triggers must match
                var allMatch = true
                if voiceTriggerSet && !voiceMatched { allMatch = false }
                if modeTriggerSet && !modeMatched { allMatch = false }
                if appTriggerSet && !appMatched { allMatch = false }
                if urlTriggerSet && !urlMatched { allMatch = false }
                finalMatched = allMatch
            }
        } else {
            // OR logic: only non-empty triggers are considered
            var anyMatch = false
            if voiceTriggerSet && voiceMatched { anyMatch = true }
            if modeTriggerSet && modeMatched { anyMatch = true }
            if appTriggerSet && appMatched { anyMatch = true }
            if urlTriggerSet && urlMatched { anyMatch = true }
            finalMatched = anyMatch
        }

        if verbose || finalMatched {
            logDebug(
                "[TriggerEval] Action '\(actionName)' final matched=\(finalMatched) " +
                "logic=\(logic) voice=\(voiceMatched) mode=\(modeMatched) app=\(appMatched) url=\(urlMatched)"
            )
        }

        return (finalMatched, strippedResult)
    }
}

// MARK: - Supporting Types and Protocols

extension TriggerEvaluator {
    private struct UrlTriggerPattern {
        let rawPattern: String
        let isFullURLToken: Bool
        let host: String
        let port: Int?
        let pathQueryPrefix: String?
    }

    private struct UrlTriggerCandidate {
        let host: String
        let port: Int?
        let pathQuery: String
    }

    private func parseUrlTriggerCandidate(from rawUrl: String) -> UrlTriggerCandidate? {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let normalizedInput: String
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            normalizedInput = trimmed
        } else {
            normalizedInput = "https://\(trimmed)"
        }

        guard let components = URLComponents(string: normalizedInput),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }

        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let pathQuery = normalizedPathQuery(path: components.percentEncodedPath, query: components.percentEncodedQuery)
        return UrlTriggerCandidate(host: normalizedHost, port: components.port, pathQuery: pathQuery)
    }

    private func parseUrlTriggerPattern(from rawPattern: String) -> UrlTriggerPattern? {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Explicit wildcard syntax is unsupported by design for URL triggers.
        guard !trimmed.contains("*") else { return nil }

        let lowercased = trimmed.lowercased()
        let isFullURLToken = lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
        let normalizedInput = isFullURLToken ? trimmed : "https://\(trimmed)"

        guard let components = URLComponents(string: normalizedInput),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }

        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let pathQueryPrefix = normalizedPathQueryPrefix(path: components.percentEncodedPath, query: components.percentEncodedQuery)
        return UrlTriggerPattern(
            rawPattern: trimmed,
            isFullURLToken: isFullURLToken,
            host: normalizedHost,
            port: components.port,
            pathQueryPrefix: pathQueryPrefix
        )
    }

    private func urlTriggerPatternMatches(_ pattern: UrlTriggerPattern, candidate: UrlTriggerCandidate) -> Bool {
        let hostMatches: Bool
        if pattern.isFullURLToken {
            hostMatches = candidate.host.caseInsensitiveCompare(pattern.host) == .orderedSame
        } else {
            let host = candidate.host.lowercased()
            let patternHost = pattern.host.lowercased()
            hostMatches = host == patternHost || host.hasSuffix(".\(patternHost)")
        }

        guard hostMatches else { return false }

        if let patternPort = pattern.port, candidate.port != patternPort {
            return false
        }

        if let pathQueryPrefix = pattern.pathQueryPrefix {
            return candidate.pathQuery.hasPrefix(pathQueryPrefix)
        }

        return true
    }

    private func normalizedPathQueryPrefix(path: String?, query: String?) -> String? {
        let normalizedPath = normalizedPath(path)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasExplicitPath = !normalizedPath.isEmpty && normalizedPath != "/"
        let hasExplicitQuery = normalizedQuery?.isEmpty == false
        guard hasExplicitPath || hasExplicitQuery else {
            return nil
        }

        var prefix = normalizedPath.isEmpty ? "/" : normalizedPath
        if let normalizedQuery, !normalizedQuery.isEmpty {
            prefix += "?\(normalizedQuery)"
        }
        return prefix.lowercased()
    }

    private func normalizedPathQuery(path: String?, query: String?) -> String {
        let normalizedPath = normalizedPath(path)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)

        var pathQuery = normalizedPath.isEmpty ? "/" : normalizedPath
        if let normalizedQuery, !normalizedQuery.isEmpty {
            pathQuery += "?\(normalizedQuery)"
        }
        return pathQuery.lowercased()
    }

    private func normalizedPath(_ path: String?) -> String {
        guard let path else { return "/" }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "/"
        }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    /// Splits a triggerVoice string into individual patterns, using '|' as separator,
    /// but ignoring '|' inside raw regex blocks delimited by '==' ... '=='.
    /// Trims whitespace around each part and removes empty parts.
    fileprivate func splitVoiceTriggers(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var i = input.startIndex
        var inRaw = false

        func pushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            current.removeAll(keepingCapacity: true)
        }

        while i < input.endIndex {
            if inRaw {
                // Look for closing '=='
                if input[i] == "=" {
                    let next = input.index(after: i)
                    if next < input.endIndex && input[next] == "=" {
                        // Append the closing '==' and exit raw mode
                        current.append("==")
                        i = input.index(after: next)
                        inRaw = false
                        continue
                    }
                }
                // Regular char inside raw
                current.append(input[i])
                i = input.index(after: i)
            } else {
                // Not in raw mode
                if input[i] == "|" {
                    pushCurrent()
                    i = input.index(after: i)
                    continue
                }
                // Enter raw mode on '=='
                if input[i] == "=" {
                    let next = input.index(after: i)
                    if next < input.endIndex && input[next] == "=" {
                        inRaw = true
                        current.append("==")
                        i = input.index(after: next)
                        continue
                    }
                }
                current.append(input[i])
                i = input.index(after: i)
            }
        }
        pushCurrent()
        return parts
    }
}

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
    var triggerUrls: String? { get }
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
    var triggerUrls: String? { insert.triggerUrls }
    var triggerLogic: String? { insert.triggerLogic }
}

struct UrlWithName: TriggerProtocol {
    let url: AppConfiguration.Url
    let name: String
    
    var triggerVoice: String? { url.triggerVoice }
    var triggerApps: String? { url.triggerApps }
    var triggerModes: String? { url.triggerModes }
    var triggerUrls: String? { url.triggerUrls }
    var triggerLogic: String? { url.triggerLogic }
}

struct ShortcutWithName: TriggerProtocol {
    let shortcut: AppConfiguration.Shortcut
    let name: String
    
    var triggerVoice: String? { shortcut.triggerVoice }
    var triggerApps: String? { shortcut.triggerApps }
    var triggerModes: String? { shortcut.triggerModes }
    var triggerUrls: String? { shortcut.triggerUrls }
    var triggerLogic: String? { shortcut.triggerLogic }
}

struct ShellWithName: TriggerProtocol {
    let shell: AppConfiguration.ScriptShell
    let name: String
    
    var triggerVoice: String? { shell.triggerVoice }
    var triggerApps: String? { shell.triggerApps }
    var triggerModes: String? { shell.triggerModes }
    var triggerUrls: String? { shell.triggerUrls }
    var triggerLogic: String? { shell.triggerLogic }
}

struct AppleScriptWithName: TriggerProtocol {
    let ascript: AppConfiguration.ScriptAppleScript
    let name: String
    
    var triggerVoice: String? { ascript.triggerVoice }
    var triggerApps: String? { ascript.triggerApps }
    var triggerModes: String? { ascript.triggerModes }
    var triggerUrls: String? { ascript.triggerUrls }
    var triggerLogic: String? { ascript.triggerLogic }
} 
