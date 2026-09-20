import Foundation
import Cocoa

/// A parsed voice trigger rule. `raw` is the exact trimmed rule from the
/// trigger list; the other fields describe the rule's matching semantics.
struct VoiceTriggerRule {
    let raw: String
    let pattern: String
    let isException: Bool
    let isSuffix: Bool
    let isRawRegex: Bool
}

/// Shared parser, matcher, and stripper for literal voice triggers.
///
/// Keeping this implementation in TriggerEvaluator.swift means the watcher,
/// CLI, and evaluator all use the same compiled runtime source without adding
/// another Xcode project file entry.
enum VoiceTriggerMatcher {
    private static let terminalPunctuation = CharacterSet(charactersIn: ".!?…")
    private static let connectorPunctuation = CharacterSet(charactersIn: ",;:-–—")
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let trailingSuffixCharacters = whitespace.union(.punctuationCharacters)

    static func split(_ input: String) -> [VoiceTriggerRule] {
        var parts: [VoiceTriggerRule] = []
        var current = ""
        var index = input.startIndex
        var inRaw = false

        func pushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let rule = parse(trimmed) {
                parts.append(rule)
            }
            current.removeAll(keepingCapacity: true)
        }

        while index < input.endIndex {
            if inRaw {
                if input[index] == "=" {
                    let next = input.index(after: index)
                    if next < input.endIndex && input[next] == "=" {
                        current.append("==")
                        index = input.index(after: next)
                        inRaw = false
                        continue
                    }
                }
                current.append(input[index])
                index = input.index(after: index)
                continue
            }

            if input[index] == "|" {
                pushCurrent()
                index = input.index(after: index)
                continue
            }
            if input[index] == "=" {
                let next = input.index(after: index)
                if next < input.endIndex && input[next] == "=" {
                    inRaw = true
                    current.append("==")
                    index = input.index(after: next)
                    continue
                }
            }
            current.append(input[index])
            index = input.index(after: index)
        }
        pushCurrent()
        return parts
    }

    static func match(_ text: String, rule: VoiceTriggerRule) -> NSTextCheckingResult? {
        let regexPattern: String
        if rule.isRawRegex {
            regexPattern = rule.pattern.hasPrefix("(?i)") || rule.pattern.hasPrefix("(?-i)")
                ? rule.pattern
                : "(?i)" + rule.pattern
        } else if rule.isSuffix {
            let literalPattern = rule.pattern
            guard !literalPattern.isEmpty else { return nil }
            regexPattern = "(?i)" + NSRegularExpression.escapedPattern(for: literalPattern)
        } else {
            guard !rule.pattern.isEmpty else { return nil }
            regexPattern = "^(?i)" + NSRegularExpression.escapedPattern(for: rule.pattern)
        }

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        if !rule.isSuffix || rule.isRawRegex {
            return regex.firstMatch(in: text, options: [], range: range)
        }

        // A suffix literal must end at the transcript's end, apart from
        // punctuation and whitespace produced by transcription.
        for candidate in regex.matches(in: text, options: [], range: range).reversed() {
            guard let candidateRange = Range(candidate.range, in: text) else { continue }
            let remainder = String(text[candidateRange.upperBound...])
            guard remainder.unicodeScalars.allSatisfy({ trailingSuffixCharacters.contains($0) }) else {
                continue
            }
            if candidateRange.lowerBound > text.startIndex {
                let previous = text.index(before: candidateRange.lowerBound)
                guard let scalar = text[previous].unicodeScalars.first,
                      trailingSuffixCharacters.contains(scalar) else {
                    continue
                }
            }
            return candidate
        }
        return nil
    }

    /// Removes a matched literal rule from `text`. Raw regexes intentionally
    /// never strip, even when they match.
    static func strip(_ text: String, using rule: VoiceTriggerRule) -> String? {
        guard !rule.isException, !rule.isRawRegex,
              let match = match(text, rule: rule),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        if rule.isSuffix {
            return stripSuffix(text, matchedRange: matchRange)
        }

        var stripped = String(text[matchRange.upperBound...])
        let punctuationAndWhitespace = whitespace.union(.punctuationCharacters)
        while let first = stripped.unicodeScalars.first,
              punctuationAndWhitespace.contains(first) {
            stripped.removeFirst()
        }
        if let first = stripped.first {
            stripped.replaceSubrange(stripped.startIndex...stripped.startIndex, with: String(first).uppercased())
        }
        return stripped
    }

    private static func parse(_ raw: String) -> VoiceTriggerRule? {
        var actualPattern = raw
        var isException = false
        if actualPattern.hasPrefix("!") {
            isException = true
            actualPattern.removeFirst()
        }

        // Raw rules retain their existing meaning. In particular, a leading
        // `*` is only a suffix marker for literal rules, not for ==...==.
        let isRawRegex = actualPattern.hasPrefix("==") && actualPattern.hasSuffix("==")
        if isRawRegex {
            let start = actualPattern.index(actualPattern.startIndex, offsetBy: 2)
            let end = actualPattern.index(actualPattern.endIndex, offsetBy: -2)
            return VoiceTriggerRule(
                raw: raw,
                pattern: String(actualPattern[start..<end]),
                isException: isException,
                isSuffix: false,
                isRawRegex: true
            )
        }

        var isSuffix = false
        if actualPattern.hasPrefix("*") {
            isSuffix = true
            actualPattern.removeFirst()
        }
        return VoiceTriggerRule(
            raw: raw,
            pattern: normalizedLiteralPattern(actualPattern),
            isException: isException,
            isSuffix: isSuffix,
            isRawRegex: false
        )
    }

    private static func normalizedLiteralPattern(_ pattern: String) -> String {
        var end = pattern.endIndex
        while end > pattern.startIndex {
            let previous = pattern.index(before: end)
            guard pattern[previous].unicodeScalars.allSatisfy({ trailingSuffixCharacters.contains($0) }) else {
                break
            }
            end = previous
        }
        return String(pattern[..<end])
    }

    private static func stripSuffix(_ text: String, matchedRange: Range<String.Index>) -> String {
        var retained = String(text[..<matchedRange.lowerBound])
        let trailing = String(text[matchedRange.upperBound...])

        // The command's trailing punctuation is transferred only when the
        // retained content does not already end in sentence punctuation.
        let terminal = terminalPunctuationCluster(in: trailing)

        retained = retained.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = retained.unicodeScalars.last, connectorPunctuation.contains(last) {
            retained.removeLast()
            retained = retained.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let hasStrongEnding = retained.unicodeScalars.last.map { terminalPunctuation.contains($0) } ?? false
        if !hasStrongEnding, !terminal.isEmpty, !retained.isEmpty {
            retained += terminal
        }
        return retained
    }

    private static func terminalPunctuationCluster(in trailing: String) -> String {
        var scalars = Array(trailing.unicodeScalars)
        while let last = scalars.last, whitespace.contains(last) {
            scalars.removeLast()
        }

        var cluster: [UnicodeScalar] = []
        while let last = scalars.last, terminalPunctuation.contains(last) {
            cluster.append(last)
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(cluster.reversed()))
    }
}

/// Handles trigger evaluation for all action types (inserts, URLs, shortcuts, shell scripts, AppleScript)
class TriggerEvaluator {
    private let logger: Logger

    /// Built-in trigger precedence. An exclusion-only match is intentionally
    /// weaker than every positive contextual match because it represents a
    /// catch-all rather than affirmative user intent.
    private enum TriggerMatchSource: Int {
        case exclusionOnly = 0
        case app = 1
        case url = 2
        case mode = 3
        case voice = 4
    }

    private struct TriggerMatchRank {
        let source: TriggerMatchSource
        let requiredConditionCount: Int
        let specificity: Int
    }

    private struct TriggerEvaluationResult {
        let matched: Bool
        let strippedResult: String?
        let matchedVoiceTrigger: VoiceTriggerRule?
        let rank: TriggerMatchRank?
    }

    private struct RankedTriggerAction {
        let action: Any
        let name: String
        let type: ActionType
        let strippedResult: String?
        let matchedVoiceTrigger: VoiceTriggerRule?
        let rank: TriggerMatchRank
    }
    
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
    ) -> [(action: Any, name: String, type: ActionType, strippedResult: String?, matchedVoiceTrigger: VoiceTriggerRule?)] {
        
        let modeName = metaJson["modeName"] as? String
        var matchedTriggerActions: [RankedTriggerAction] = []
        
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
            let evaluation = triggersMatch(
                for: insertWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if evaluation.matched, let rank = evaluation.rank {
                matchedTriggerActions.append(
                    RankedTriggerAction(
                        action: insert,
                        name: name,
                        type: .insert,
                        strippedResult: evaluation.strippedResult,
                        matchedVoiceTrigger: evaluation.matchedVoiceTrigger,
                        rank: rank
                    )
                )
            }
        }
        
        // Evaluate all URL actions for triggers
        for (name, url) in configManager.config.urls {
            let urlWithName = UrlWithName(url: url, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking URL action: name=\(name), triggerVoice=\(summarizeForLogs(url.triggerVoice)), triggerApps=\(summarizeForLogs(url.triggerApps)), triggerModes=\(summarizeForLogs(url.triggerModes)), triggerUrls=\(summarizeForLogs(url.triggerUrls)), triggerLogic=\(url.triggerLogic ?? "nil")")
            }
            let evaluation = triggersMatch(
                for: urlWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if evaluation.matched, let rank = evaluation.rank {
                matchedTriggerActions.append(
                    RankedTriggerAction(
                        action: url,
                        name: name,
                        type: .url,
                        strippedResult: evaluation.strippedResult,
                        matchedVoiceTrigger: evaluation.matchedVoiceTrigger,
                        rank: rank
                    )
                )
            }
        }
        
        // Evaluate all shortcut actions for triggers
        for (name, shortcut) in configManager.config.shortcuts {
            let shortcutWithName = ShortcutWithName(shortcut: shortcut, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking shortcut action: name=\(name), triggerVoice=\(summarizeForLogs(shortcut.triggerVoice)), triggerApps=\(summarizeForLogs(shortcut.triggerApps)), triggerModes=\(summarizeForLogs(shortcut.triggerModes)), triggerUrls=\(summarizeForLogs(shortcut.triggerUrls)), triggerLogic=\(shortcut.triggerLogic ?? "nil")")
            }
            let evaluation = triggersMatch(
                for: shortcutWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if evaluation.matched, let rank = evaluation.rank {
                matchedTriggerActions.append(
                    RankedTriggerAction(
                        action: shortcut,
                        name: name,
                        type: .shortcut,
                        strippedResult: evaluation.strippedResult,
                        matchedVoiceTrigger: evaluation.matchedVoiceTrigger,
                        rank: rank
                    )
                )
            }
        }
        
        // Evaluate all shell script actions for triggers
        for (name, shell) in configManager.config.scriptsShell {
            let shellWithName = ShellWithName(shell: shell, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking shell script action: name=\(name), triggerVoice=\(summarizeForLogs(shell.triggerVoice)), triggerApps=\(summarizeForLogs(shell.triggerApps)), triggerModes=\(summarizeForLogs(shell.triggerModes)), triggerUrls=\(summarizeForLogs(shell.triggerUrls)), triggerLogic=\(shell.triggerLogic ?? "nil")")
            }
            let evaluation = triggersMatch(
                for: shellWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if evaluation.matched, let rank = evaluation.rank {
                matchedTriggerActions.append(
                    RankedTriggerAction(
                        action: shell,
                        name: name,
                        type: .shell,
                        strippedResult: evaluation.strippedResult,
                        matchedVoiceTrigger: evaluation.matchedVoiceTrigger,
                        rank: rank
                    )
                )
            }
        }
        
        // Evaluate all AppleScript actions for triggers
        for (name, ascript) in configManager.config.scriptsAS {
            let ascriptWithName = AppleScriptWithName(ascript: ascript, name: name)
            if isVerboseLogDetailEnabled() {
                logDebug("[TriggerEval] Checking AppleScript action: name=\(name), triggerVoice=\(summarizeForLogs(ascript.triggerVoice)), triggerApps=\(summarizeForLogs(ascript.triggerApps)), triggerModes=\(summarizeForLogs(ascript.triggerModes)), triggerUrls=\(summarizeForLogs(ascript.triggerUrls)), triggerLogic=\(ascript.triggerLogic ?? "nil")")
            }
            let evaluation = triggersMatch(
                for: ascriptWithName,
                result: result,
                modeName: modeName,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            if evaluation.matched, let rank = evaluation.rank {
                matchedTriggerActions.append(
                    RankedTriggerAction(
                        action: ascript,
                        name: name,
                        type: .appleScript,
                        strippedResult: evaluation.strippedResult,
                        matchedVoiceTrigger: evaluation.matchedVoiceTrigger,
                        rank: rank
                    )
                )
            }
        }

        let sortedMatches = matchedTriggerActions.sorted(by: triggerMatchPrecedes)

        // Log evaluation summary at end
        let matchedNames = sortedMatches.map { $0.name }.joined(separator: ", ")
        if sortedMatches.isEmpty {
            logInfo("[TriggerEval] No actions matched triggers")
        } else {
            logInfo("[TriggerEval] \(sortedMatches.count) action(s) matched triggers in priority order: \(matchedNames)")
        }

        return sortedMatches.map {
            (
                action: $0.action,
                name: $0.name,
                type: $0.type,
                strippedResult: $0.strippedResult,
                matchedVoiceTrigger: $0.matchedVoiceTrigger
            )
        }
    }

    private func triggerMatchPrecedes(_ lhs: RankedTriggerAction, _ rhs: RankedTriggerAction) -> Bool {
        if lhs.rank.source.rawValue != rhs.rank.source.rawValue {
            return lhs.rank.source.rawValue > rhs.rank.source.rawValue
        }
        if lhs.rank.requiredConditionCount != rhs.rank.requiredConditionCount {
            return lhs.rank.requiredConditionCount > rhs.rank.requiredConditionCount
        }
        if lhs.rank.specificity != rhs.rank.specificity {
            return lhs.rank.specificity > rhs.rank.specificity
        }

        let localizedOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if localizedOrder != .orderedSame {
            return localizedOrder == .orderedAscending
        }

        // Keep case-only names deterministic even though config validation treats
        // them as distinct action names.
        return lhs.name < rhs.name
    }
    
    /// Helper to evaluate triggers for a given action
    private func triggersMatch<T: TriggerProtocol>(
        for action: T,
        result: String,
        modeName: String?,
        frontAppName: String?,
        frontAppBundleId: String?,
        frontAppUrl: String?
    ) -> TriggerEvaluationResult {
        let verbose = isVerboseLogDetailEnabled()
        var voiceMatched = false
        var modeMatched = false
        var appMatched = false
        var urlMatched = false
        var strippedResult: String? = nil
        var matchedVoiceTrigger: VoiceTriggerRule? = nil
        var matchedVoiceTriggerLength = -1
        var voicePositivePatternMatched = false
        var modePositivePatternMatched = false
        var appPositivePatternMatched = false
        var urlPositivePatternMatched = false
        var voiceSpecificity = 0
        var urlSpecificity = 0
        
        let triggerVoice = action.triggerVoice
        let triggerModes = action.triggerModes
        let triggerApps = action.triggerApps
        let triggerUrls = action.triggerUrls
        let triggerLogic = action.triggerLogic
        let actionName = action.name
        let logic = (triggerLogic ?? "or").lowercased()

        guard logic == "and" || logic == "or" else {
            logError(
                "[TriggerEval] Action '\(actionName)' has invalid triggerLogic '\(triggerLogic ?? "nil")'. " +
                "Skipping trigger evaluation for this action."
            )
            return TriggerEvaluationResult(
                matched: false,
                strippedResult: nil,
                matchedVoiceTrigger: nil,
                rank: nil
            )
        }
        
        // Voice trigger
        if let triggerVoice = triggerVoice, !triggerVoice
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            let triggers = VoiceTriggerMatcher.split(triggerVoice)
            var matched = false
            var exceptionMatched = false
            if verbose {
                if redactedLogsEnabled {
                    logDebug("[TriggerEval] Voice trigger check for action '\(actionName)': patterns=[REDACTED count=\(triggers.count)]")
                } else {
                    logDebug("[TriggerEval] Voice trigger check for action '\(actionName)': patterns=\(triggers.map(\.raw))")
                }
            }
            
            for trigger in triggers {
                let match = VoiceTriggerMatcher.match(result, rule: trigger)
                let found = match != nil
                if found {
                    if verbose || found {
                        logDebug(
                            "[TriggerEval] Voice pattern \(summarizeForLogs(trigger.raw, maxPreview: 80)) " +
                            "(raw regex: \(trigger.isRawRegex)) found=\(found) " +
                            "input=\(summarizeForLogs(result, maxPreview: 120)) " +
                            "rule=\(summarizeForLogs(trigger.raw, maxPreview: 120))"
                        )
                    }
                    
                    if trigger.isException {
                        exceptionMatched = true
                    }
                    if !trigger.isException {
                        matched = true
                        voicePositivePatternMatched = true
                        if let match {
                            voiceSpecificity = max(voiceSpecificity, match.range.length)
                        }
                        if !trigger.isRawRegex, let stripped = VoiceTriggerMatcher.strip(result, using: trigger) {
                            let matchLength = match?.range.length ?? 0
                            let shouldReplace = matchedVoiceTrigger == nil ||
                                matchedVoiceTrigger?.isRawRegex == true ||
                                matchLength > matchedVoiceTriggerLength
                            if shouldReplace {
                                strippedResult = stripped
                                matchedVoiceTrigger = trigger
                                matchedVoiceTriggerLength = matchLength
                            }
                        } else if matchedVoiceTrigger == nil {
                            // Preserve the exact raw rule for diagnostics and
                            // propagation, although raw rules never strip.
                            matchedVoiceTrigger = trigger
                        }
                    }
                }
            }
            
            let hasPositive = triggers.contains { !$0.isException }
            let hasException = triggers.contains { $0.isException }
            
            if hasPositive {
                voiceMatched = matched && !exceptionMatched
            } else if hasException {
                // Only exceptions: match if no exception matched
                voiceMatched = !exceptionMatched
            } else {
                // No patterns at all (shouldn't happen), treat as matched
                voiceMatched = true
            }
            voicePositivePatternMatched = voiceMatched && voicePositivePatternMatched
            if verbose || voiceMatched {
                logDebug("[TriggerEval] Voice trigger result for action '\(actionName)': matched=\(voiceMatched)")
            }
        } else {
            // No voice trigger set, will be handled in final logic determination
            voiceMatched = true
        }
        
        // Mode trigger
        if let triggerModes = triggerModes, !triggerModes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let modeName = modeName, !modeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        if !isException && found {
                            matched = true
                            modePositivePatternMatched = true
                        }
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
                modePositivePatternMatched = modeMatched && modePositivePatternMatched
                if verbose || modeMatched {
                    logDebug("[TriggerEval] Mode trigger result for action '\(actionName)': matched=\(modeMatched)")
                }
            } else {
                if verbose {
                    logDebug("[TriggerEval] Mode trigger set for action '\(actionName)' but modeName is missing or empty. Not matching.")
                }
                modeMatched = false
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
                        if !isException && found {
                            matched = true
                            appPositivePatternMatched = true
                        }
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
                appPositivePatternMatched = appMatched && appPositivePatternMatched
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
                    if !isException && found {
                        matched = true
                        urlPositivePatternMatched = true
                        urlSpecificity = max(urlSpecificity, urlTriggerSpecificity(parsedPattern))
                    }
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
                urlPositivePatternMatched = urlMatched && urlPositivePatternMatched
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

        let source: TriggerMatchSource
        if voiceTriggerSet && voiceMatched && voicePositivePatternMatched {
            source = .voice
        } else if modeTriggerSet && modeMatched && modePositivePatternMatched {
            source = .mode
        } else if urlTriggerSet && urlMatched && urlPositivePatternMatched {
            source = .url
        } else if appTriggerSet && appMatched && appPositivePatternMatched {
            source = .app
        } else {
            source = .exclusionOnly
        }

        let configuredConditionCount = [voiceTriggerSet, modeTriggerSet, appTriggerSet, urlTriggerSet]
            .filter { $0 }
            .count
        let requiredConditionCount = logic == "and" ? configuredConditionCount : 1
        let specificity: Int
        switch source {
        case .voice:
            specificity = voiceSpecificity
        case .url:
            specificity = urlSpecificity
        case .mode, .app, .exclusionOnly:
            specificity = 0
        }

        let rank = finalMatched
            ? TriggerMatchRank(
                source: source,
                requiredConditionCount: requiredConditionCount,
                specificity: specificity
            )
            : nil
        let effectiveStrippedResult = voiceTriggerSet && voiceMatched && voicePositivePatternMatched
            ? strippedResult
            : nil
        let effectiveMatchedVoiceTrigger = voiceTriggerSet && voiceMatched && voicePositivePatternMatched
            ? matchedVoiceTrigger
            : nil

        return TriggerEvaluationResult(
            matched: finalMatched,
            strippedResult: effectiveStrippedResult,
            matchedVoiceTrigger: effectiveMatchedVoiceTrigger,
            rank: rank
        )
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

    private func urlTriggerSpecificity(_ pattern: UrlTriggerPattern) -> Int {
        let pathQueryLength = pattern.pathQueryPrefix?.count ?? 0
        let hasPathQueryBonus = pathQueryLength > 0 ? 1_000_000 : 0
        let exactHostBonus = pattern.isFullURLToken ? 100_000 : 0
        let portBonus = pattern.port == nil ? 0 : 10_000
        return hasPathQueryBonus + exactHostBonus + portBonus + (pathQueryLength * 100) + pattern.host.count
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
