import ApplicationServices
import Cocoa
import NaturalLanguage

private let appVocabularyMaxTraversalDepth = 4 //Used in tree crawl
private let appVocabularyMaxVisitedNodes = 360 //Hard cap on AX elements visited
private let appVocabularyMaxSnippets = 460 //text chunks/groups
private let appVocabularyMaxSnippetLength = 320 //snippet length outside .value (non-input fields)
private let appVocabularyMaxLongTextSnippetLength = 2600 //long descriptive text (titles/descriptions/help)
private let appVocabularyMaxValueSnippetLength = 4000 //snippet length inside .value (input fields)
private let appVocabularyMaxOutputTokens = 220 //total output terms after filtering and rules

// Intentionally small stopword set for high-frequency noise that still passes case/shape scoring.
private let appVocabularyCoreStopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "have", "if", "in", "into",
    "is", "it", "its", "of", "on", "or", "that", "the", "their", "then", "there", "these", "this", "to",
    "was", "were", "will", "with", "you", "your", "not", "all", "any", "can", "do", "does", "done"
]

// UI chrome labels that are frequently surfaced by accessibility trees but rarely useful as vocabulary.
private let appVocabularyUIStopWords: Set<String> = [
    "open", "close", "copy", "paste", "edit", "view", "help", "file", "window", "tab", "menu", "button",
    "label", "title", "description", "placeholder", "search", "text", "content", "filter", "toggle",
    "keyboard", "shortcuts", "navigation", "section", "header", "body", "message", "messages", "select",
    "group", "cursor", "arrow", "press", "user"
]

private let appVocabularyStopWords = appVocabularyCoreStopWords.union(appVocabularyUIStopWords)

private let appVocabularyAllowedShortAcronyms: Set<String> = [
    "AI", "API", "CLI", "CSS", "CSV", "GPT", "HTML", "HTTP", "HTTPS", "ID", "IDS",
    "IP", "JS", "JSON", "LLM", "ML", "OCR", "QA", "SQL", "TS", "UI", "URL", "URLS", "UX", "XML"
]

let appVocabularyBrowserBundleIds: Set<String> = [
    "com.apple.Safari",
    "com.google.Chrome",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser",
    "org.chromium.Chromium"
]

private let appVocabularyBrowserContentRoles: Set<String> = [
    "AXWebArea",
    "AXStaticText",
    "AXTextArea",
    "AXLink",
    "AXHeading",
    "AXGroup"
]

private enum VocabularySource {
    case appName
    case windowTitle
    case title
    case label
    case placeholder
    case description
    case help
    case value
}

private struct VocabularySnippet {
    let text: String
    let source: VocabularySource
}

private struct VocabularyCandidate {
    var token: String
    var score: Int
    var count: Int
}

/// Extracts vocabulary-like terms (names, nouns, identifiers) from the frontmost app lazily at execution time.
/// Output is a comma-separated list suitable for prompt placeholders.
func getAppVocabulary() -> String {
    guard AXIsProcessTrusted() else {
        logDebug("[AppVocabulary] No accessibility permissions, cannot get app vocabulary")
        return ""
    }

    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        logDebug("[AppVocabulary] No frontmost application found")
        return ""
    }

    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var snippets: [VocabularySnippet] = []
    let directInputContent = getInputFieldContent(appElement: appElement)
    let hasDirectInputContent = !(directInputContent?.isEmpty ?? true)
    let isBrowserApp = appVocabularyBrowserBundleIds.contains(frontApp.bundleIdentifier ?? "")

    if let appName = frontApp.localizedName, !appName.isEmpty {
        let cleaned = normalizeVocabularySnippet(appName, source: .appName)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .appName))
        }
    }

    var focusedWindow: CFTypeRef?
    let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    if focusedWindowError == .success, let focusedWindow = focusedWindow {
        let windowElement = focusedWindow as! AXUIElement
        var windowTitleValue: CFTypeRef?
        let windowTitleError = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &windowTitleValue)
        if windowTitleError == .success, let title = windowTitleValue as? String, !title.isEmpty {
            let cleaned = normalizeVocabularySnippet(title, source: .windowTitle)
            if !cleaned.isEmpty {
                snippets.append(VocabularySnippet(text: cleaned, source: .windowTitle))
            }
        }

        // When focused input content is available, avoid broad window crawling to reduce UI noise.
        if !hasDirectInputContent {
            if isBrowserApp {
                if let webArea = findFirstElement(withRole: "AXWebArea", from: windowElement, maxDepth: 10, maxNodes: 2200) {
                    if let parameterizedWebText = extractWebAreaParameterizedText(webArea, maxCharacters: 12000) {
                        let cleaned = normalizeVocabularySnippet(parameterizedWebText, source: .description)
                        if !cleaned.isEmpty {
                            snippets.append(VocabularySnippet(text: cleaned, source: .description))
                        }
                    }

                    let webSnippets = collectVocabularySnippets(
                        from: webArea,
                        maxDepth: 6,
                        maxNodes: 900,
                        maxSnippets: 700
                    )
                    snippets.append(contentsOf: webSnippets)
                }
            } else {
                let windowSnippets = collectVocabularySnippets(
                    from: windowElement,
                    maxDepth: appVocabularyMaxTraversalDepth,
                    maxNodes: appVocabularyMaxVisitedNodes,
                    maxSnippets: appVocabularyMaxSnippets
                )
                snippets.append(contentsOf: windowSnippets)
            }
        }
    }

    // Use the same focused-element data paths as appContext for better reliability in input-field workflows.
    if let inputContent = directInputContent, !inputContent.isEmpty {
        let cleaned = normalizeVocabularySnippet(inputContent, source: .value)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .value))
        }
    }

    if let elementDescription = getFocusedElementDescription(appElement: appElement), !elementDescription.isEmpty {
        let cleaned = normalizeVocabularySnippet(elementDescription, source: .description)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .description))
        }
    }

    if let focusedRawText = getFocusedElementRawText(appElement: appElement), !focusedRawText.isEmpty {
        let cleaned = normalizeVocabularySnippet(focusedRawText, source: .description)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .description))
        }
    }

    var focusedElement: CFTypeRef?
    let focusedElementError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    if !hasDirectInputContent, focusedElementError == .success, let focusedElement = focusedElement {
        let focusedAx = focusedElement as! AXUIElement
        if isBrowserApp, let role = getAXRole(of: focusedAx), !appVocabularyBrowserContentRoles.contains(role) {
            // Ignore focused browser chrome widgets when outside input fields.
        } else {
            let focusedSnippets = collectVocabularySnippets(
                from: focusedAx,
                maxDepth: isBrowserApp ? 3 : 2,
                maxNodes: isBrowserApp ? 180 : 90,
                maxSnippets: isBrowserApp ? 220 : 100
            )
            snippets.append(contentsOf: focusedSnippets)
        }
    }

    let tokens = extractVocabularyTokens(
        from: snippets,
        maxTokens: appVocabularyMaxOutputTokens,
        isInputFocused: hasDirectInputContent,
        isBrowserApp: isBrowserApp
    )
    if tokens.isEmpty {
        logDebug("[AppVocabulary] No vocabulary terms extracted")
        return ""
    }

    let result = tokens.joined(separator: ", ")
    logDebug("[AppVocabulary] Extracted \(tokens.count) vocabulary terms")
    return result
}

private func collectVocabularySnippets(
    from root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    maxSnippets: Int,
    excludedRoles: Set<String> = []
) -> [VocabularySnippet] {
    var snippets: [VocabularySnippet] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var visitedCount = 0

    while index < queue.count && visitedCount < maxNodes && snippets.count < maxSnippets {
        let (element, depth) = queue[index]
        index += 1
        visitedCount += 1

        let role = getAXRole(of: element)
        if role == nil || !excludedRoles.contains(role!) {
            let elementSnippets = getVocabularyTextAttributes(from: element)
            for snippet in elementSnippets {
                if snippets.count >= maxSnippets {
                    break
                }
                snippets.append(snippet)
            }
        }

        if depth >= maxDepth {
            continue
        }

        var childrenValue: CFTypeRef?
        let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if childrenError == .success, let children = childrenValue as? [AXUIElement], !children.isEmpty {
            for child in children {
                queue.append((child, depth + 1))
                if queue.count >= (maxNodes * 2) {
                    break
                }
            }
        }
    }

    return snippets
}

private func getAXRole(of element: AXUIElement) -> String? {
    var roleValue: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
    guard roleError == .success, let role = roleValue as? String, !role.isEmpty else {
        return nil
    }
    return role
}

func findFirstElement(withRole targetRole: String, from root: AXUIElement, maxDepth: Int, maxNodes: Int) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var visited = 0

    while index < queue.count, visited < maxNodes {
        let (element, depth) = queue[index]
        index += 1
        visited += 1

        if getAXRole(of: element) == targetRole {
            return element
        }

        if depth >= maxDepth {
            continue
        }

        var childrenValue: CFTypeRef?
        let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if childrenError == .success, let children = childrenValue as? [AXUIElement], !children.isEmpty {
            for child in children {
                queue.append((child, depth + 1))
            }
        }
    }

    return nil
}

func buildBrowserWebContentSample(from webArea: AXUIElement, maxCharacters: Int) -> String {
    if let parameterizedText = extractWebAreaParameterizedText(webArea, maxCharacters: maxCharacters), !parameterizedText.isEmpty {
        return parameterizedText
    }

    let snippets = collectVocabularySnippets(
        from: webArea,
        maxDepth: 5,
        maxNodes: 900,
        maxSnippets: 700
    )

    var seen = Set<String>()
    var parts: [String] = []
    var currentLength = 0

    for snippet in snippets {
        let compact = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 4 else { continue }
        guard !seen.contains(compact) else { continue }
        seen.insert(compact)

        let separator = parts.isEmpty ? 0 : 1
        if currentLength + separator + compact.count > maxCharacters {
            break
        }
        parts.append(compact)
        currentLength += separator + compact.count
    }

    return parts.joined(separator: "\n")
}

private func extractWebAreaParameterizedText(_ webArea: AXUIElement, maxCharacters: Int) -> String? {
    if let fullRange = getWebAreaCharacterRange(webArea),
       let text = copyParameterizedText(from: webArea, range: fullRange),
       !text.isEmpty {
        return trimToMaximumCharacters(text, maxCharacters: maxCharacters)
    }

    if let visibleRange = getWebAreaVisibleRange(webArea),
       let text = copyParameterizedText(from: webArea, range: visibleRange),
       !text.isEmpty {
        return trimToMaximumCharacters(text, maxCharacters: maxCharacters)
    }

    return nil
}

private func getWebAreaCharacterRange(_ webArea: AXUIElement) -> CFRange? {
    var charactersValue: CFTypeRef?
    let countError = AXUIElementCopyAttributeValue(webArea, "AXNumberOfCharacters" as CFString, &charactersValue)
    if countError == .success,
       let number = charactersValue as? NSNumber {
        let count = max(0, number.intValue)
        return CFRange(location: 0, length: count)
    }
    return nil
}

private func getWebAreaVisibleRange(_ webArea: AXUIElement) -> CFRange? {
    var visibleRangeValue: CFTypeRef?
    let rangeError = AXUIElementCopyAttributeValue(webArea, "AXVisibleCharacterRange" as CFString, &visibleRangeValue)
    guard rangeError == .success,
          let visibleRangeValue = visibleRangeValue,
          CFGetTypeID(visibleRangeValue) == AXValueGetTypeID() else {
        return nil
    }

    let axRange = unsafeBitCast(visibleRangeValue, to: AXValue.self)
    guard AXValueGetType(axRange) == .cfRange else { return nil }

    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(axRange, .cfRange, &range) else {
        return nil
    }
    return range
}

private func copyParameterizedText(from element: AXUIElement, range: CFRange) -> String? {
    var mutableRange = range
    guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
        return nil
    }

    var textValue: CFTypeRef?
    let stringError = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, rangeValue, &textValue)
    if stringError == .success, let text = textValue as? String, !text.isEmpty {
        return text
    }

    textValue = nil
    let attributedError = AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForRange" as CFString, rangeValue, &textValue)
    if attributedError == .success, let attributed = textValue as? NSAttributedString, !attributed.string.isEmpty {
        return attributed.string
    }

    return nil
}

private func trimToMaximumCharacters(_ text: String, maxCharacters: Int) -> String {
    let compact = text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard compact.count > maxCharacters else { return compact }
    return String(compact.prefix(maxCharacters))
}

private func getFocusedElementRawText(appElement: AXUIElement) -> String? {
    var focusedElement: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    guard focusedError == .success, let focusedElement = focusedElement else {
        return nil
    }

    let element = focusedElement as! AXUIElement
    let prioritizedAttributes: [CFString] = [
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXHelpAttribute as CFString
    ]

    var bestText: String?
    for attribute in prioritizedAttributes {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value = value else { continue }

        let extracted = extractTextValuesFromAXAttribute(value)
        for candidate in extracted {
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 20 else { continue }
            if bestText == nil || cleaned.count > bestText!.count {
                bestText = cleaned
            }
        }
    }

    return bestText
}

private func getVocabularyTextAttributes(from element: AXUIElement) -> [VocabularySnippet] {
    let attributes: [(name: CFString, source: VocabularySource)] = [
        (kAXTitleAttribute as CFString, .title),
        ("AXLabel" as CFString, .label),
        (kAXDescriptionAttribute as CFString, .description),
        (kAXHelpAttribute as CFString, .help),
        ("AXPlaceholderValue" as CFString, .placeholder),
        (kAXValueAttribute as CFString, .value)
    ]

    var snippets: [VocabularySnippet] = []
    for (attribute, source) in attributes {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value = value else { continue }
        let rawTexts = extractTextValuesFromAXAttribute(value)
        guard !rawTexts.isEmpty else { continue }

        var seen = Set<String>()
        for text in rawTexts {
            let cleaned = normalizeVocabularySnippet(text, source: source)
            guard !cleaned.isEmpty else { continue }
            if seen.contains(cleaned) { continue }
            seen.insert(cleaned)
            snippets.append(VocabularySnippet(text: cleaned, source: source))
        }
    }

    return snippets
}

private func normalizeVocabularySnippet(_ text: String, source: VocabularySource) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let compact = trimmed
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard compact.count > 1 else { return "" }

    let maxLength: Int
    switch source {
    case .value:
        maxLength = appVocabularyMaxValueSnippetLength
    case .description, .title, .help:
        maxLength = appVocabularyMaxLongTextSnippetLength
    default:
        maxLength = appVocabularyMaxSnippetLength
    }
    if compact.count > maxLength {
        return String(compact.prefix(maxLength))
    }
    return compact
}

private func extractTextValuesFromAXAttribute(_ value: Any) -> [String] {
    var results: [String] = []
    appendTextValues(from: value, into: &results, depth: 0, maxDepth: 4)

    var deduped: [String] = []
    var seen = Set<String>()
    for raw in results {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { continue }
        if seen.contains(cleaned) { continue }
        seen.insert(cleaned)
        deduped.append(cleaned)
    }
    return deduped
}

private func appendTextValues(from value: Any, into results: inout [String], depth: Int, maxDepth: Int) {
    guard depth <= maxDepth else { return }

    if let str = value as? String {
        results.append(str)
        return
    }

    if let attributed = value as? NSAttributedString {
        results.append(attributed.string)
        return
    }

    if value is NSNumber || value is NSNull || value is Bool {
        return
    }

    if let array = value as? [Any] {
        for item in array {
            appendTextValues(from: item, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let nsArray = value as? NSArray {
        for item in nsArray {
            appendTextValues(from: item, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let dict = value as? [String: Any] {
        for dictValue in dict.values {
            appendTextValues(from: dictValue, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let nsDict = value as? NSDictionary {
        for dictValue in nsDict.allValues {
            appendTextValues(from: dictValue, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let object = value as? NSObject {
        let candidateSelectors = ["label", "value", "title", "string", "attributedValue", "attributedString"]
        for selectorName in candidateSelectors {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector), let unmanaged = object.perform(selector) else { continue }
            appendTextValues(from: unmanaged.takeUnretainedValue(), into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

private func extractVocabularyTokens(
    from snippets: [VocabularySnippet],
    maxTokens: Int,
    isInputFocused: Bool,
    isBrowserApp: Bool
) -> [String] {
    let tokenRegex = try? NSRegularExpression(pattern: "\\b[\\p{L}_][\\p{L}\\p{N}_]{1,}\\b", options: [])
    let identifierRegex = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_-])(?:--)?[\\p{L}_][\\p{L}\\p{N}_-]{1,}(?:\\.[\\p{L}\\p{N}_-]+)*(?![\\p{L}\\p{N}_-])",
        options: []
    )
    let nlTokenBonuses = buildNaturalLanguageTokenBonuses(from: snippets)
    var candidates: [String: VocabularyCandidate] = [:]

    for snippet in snippets {
        let range = NSRange(snippet.text.startIndex..., in: snippet.text)
        var processedRanges = Set<String>()

        if let tokenRegex = tokenRegex {
            let matches = tokenRegex.matches(in: snippet.text, options: [], range: range)
            for match in matches {
                let rangeKey = "\(match.range.location):\(match.range.length)"
                if processedRanges.contains(rangeKey) { continue }
                processedRanges.insert(rangeKey)
                guard let tokenRange = Range(match.range, in: snippet.text) else { continue }
                let token = String(snippet.text[tokenRange])
                guard shouldKeepVocabularyToken(token, source: snippet.source) else { continue }
                let isSentenceStart = isLikelySentenceStartToken(in: snippet.text, matchRange: match.range)
                let tokenScore = scoreVocabularyToken(
                    token,
                    source: snippet.source,
                    isSentenceStart: isSentenceStart,
                    isInputFocused: isInputFocused,
                    isBrowserApp: isBrowserApp,
                    nlBonus: nlTokenBonuses[token.lowercased()] ?? 0
                )
                upsertVocabularyCandidate(token: token, score: tokenScore, candidates: &candidates)
            }
        }

        if let identifierRegex = identifierRegex {
            let matches = identifierRegex.matches(in: snippet.text, options: [], range: range)
            for match in matches {
                let rangeKey = "\(match.range.location):\(match.range.length)"
                if processedRanges.contains(rangeKey) { continue }
                processedRanges.insert(rangeKey)
                guard let tokenRange = Range(match.range, in: snippet.text) else { continue }
                let token = String(snippet.text[tokenRange])
                guard shouldKeepVocabularyToken(token, source: snippet.source) else { continue }
                let isSentenceStart = isLikelySentenceStartToken(in: snippet.text, matchRange: match.range)
                let tokenScore = scoreVocabularyToken(
                    token,
                    source: snippet.source,
                    isSentenceStart: isSentenceStart,
                    isInputFocused: isInputFocused,
                    isBrowserApp: isBrowserApp,
                    nlBonus: nlTokenBonuses[token.lowercased()] ?? 0
                )
                upsertVocabularyCandidate(token: token, score: tokenScore, candidates: &candidates)
            }
        }
    }

    let sorted = candidates.values.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending
    }

    let minimumScore = 3
    return sorted
        .filter { $0.score >= minimumScore }
        .prefix(maxTokens)
        .map { $0.token }
}

private func shouldKeepVocabularyToken(_ token: String, source: VocabularySource) -> Bool {
    if token.count < 2 {
        return false
    }

    let trimmedToken = token.hasPrefix("--") ? String(token.dropFirst(2)) : token
    guard trimmedToken.count >= 2 else { return false }

    let lowercase = trimmedToken.lowercased()
    if appVocabularyStopWords.contains(lowercase) {
        return false
    }

    if lowercase.hasPrefix("ax") {
        return false
    }

    if lowercase.hasPrefix("http") || lowercase.hasPrefix("www") {
        return false
    }

    if trimmedToken.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
        return false
    }

    if isLikelyInternalUIToken(trimmedToken) {
        return false
    }

    // Keep short tokens only when they match useful acronyms.
    if trimmedToken.count <= 2 {
        return appVocabularyAllowedShortAcronyms.contains(trimmedToken.uppercased())
    }

    // Global strictness: keep only structured identifier-like tokens or title/upper-case terms.
    if !isPreferredVocabularyToken(token: token, trimmedToken: trimmedToken) {
        return false
    }

    return true
}

private func isPreferredVocabularyToken(token: String, trimmedToken: String) -> Bool {
    if token.hasPrefix("--") {
        return true
    }

    if looksIdentifierLike(trimmedToken) {
        return true
    }

    if trimmedToken.first?.isUppercase == true {
        return true
    }

    let hasLetter = trimmedToken.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    if hasLetter && trimmedToken == trimmedToken.uppercased() && trimmedToken.count >= 2 {
        return true
    }

    return false
}

private func scoreVocabularyToken(
    _ token: String,
    source: VocabularySource,
    isSentenceStart: Bool,
    isInputFocused: Bool,
    isBrowserApp: Bool,
    nlBonus: Int
) -> Int {
    var score = baseScore(for: source)

    if token.first?.isUppercase == true {
        score += 2
    } else {
        if source == .value || source == .description {
            score += 0
        } else {
            score -= 2
        }
    }

    if looksIdentifierLike(token) {
        score += 5
    }

    if hasMixedCaps(token) {
        score += 3
    }

    if token == token.uppercased(), token.count <= 8 {
        score += 2
    }

    if token.hasPrefix("--") {
        score += 4
    }

    if token.contains("-") {
        score += 2
    }

    if token == token.lowercased() && token.count > 3 {
        if source == .value || source == .description {
            score -= 1
        } else {
            score -= 3
        }
    }

    // Strongly suppress sentence-initial prose words from focused field content.
    if source == .value && isSentenceStart && !looksIdentifierLike(token) {
        score -= 2
    }

    if !isInputFocused && (source == .label || source == .title || source == .placeholder) {
        score -= 2
    }

    if isBrowserApp && !isInputFocused {
        if source == .appName {
            score -= 5
        } else if source == .windowTitle {
            score -= 2
        }
    }

    if isBrowserApp && !looksIdentifierLike(token) {
        score += nlBonus
    } else {
        score += (nlBonus / 2)
    }

    return score
}

private func baseScore(for source: VocabularySource) -> Int {
    switch source {
    case .appName: return 8
    case .windowTitle: return 6
    case .title: return 4
    case .label: return 4
    case .placeholder: return 3
    case .description: return 4
    case .help: return 2
    case .value: return 5
    }
}

private func looksIdentifierLike(_ token: String) -> Bool {
    if token.contains("_") {
        return true
    }

    if token.contains("-") {
        return true
    }

    let hasUppercase = token.contains { $0.isUppercase }
    let hasLowercase = token.contains { $0.isLowercase }
    if hasUppercase && hasLowercase {
        return true // camelCase / PascalCase
    }

    let hasLetter = token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    if hasLetter && hasDigit {
        return true
    }

    return false
}

private func upsertVocabularyCandidate(token: String, score: Int, candidates: inout [String: VocabularyCandidate]) {
    let key = token.lowercased()
    if var existing = candidates[key] {
        existing.count += 1
        if score > existing.score {
            existing.score = score
            existing.token = token
        }
        candidates[key] = existing
    } else {
        candidates[key] = VocabularyCandidate(token: token, score: score, count: 1)
    }
}

private func buildNaturalLanguageTokenBonuses(from snippets: [VocabularySnippet]) -> [String: Int] {
    var bonuses: [String: Int] = [:]

    for snippet in snippets {
        guard !snippet.text.isEmpty else { continue }
        let text = snippet.text
        let fullRange = text.startIndex..<text.endIndex

        let lexicalTagger = NLTagger(tagSchemes: [.lexicalClass])
        lexicalTagger.string = text
        lexicalTagger.enumerateTags(in: fullRange, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard let tag = tag else { return true }
            if tag == .noun {
                let token = String(text[range])
                addNaturalLanguageBonus(for: token, amount: 2, bonuses: &bonuses)
            }
            return true
        }

        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = text
        nameTagger.enumerateTags(in: fullRange, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard let tag = tag else { return true }
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                let token = String(text[range])
                addNaturalLanguageBonus(for: token, amount: 4, bonuses: &bonuses)
            }
            return true
        }
    }

    return bonuses
}

private func addNaturalLanguageBonus(for token: String, amount: Int, bonuses: inout [String: Int]) {
    let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;!?()[]{}<>"))
    guard normalized.count >= 2 else { return }
    let key = normalized.lowercased()
    bonuses[key, default: 0] += amount
}

private func hasMixedCaps(_ token: String) -> Bool {
    let hasUppercase = token.contains { $0.isUppercase }
    let hasLowercase = token.contains { $0.isLowercase }
    return hasUppercase && hasLowercase
}

private func isLikelySentenceStartToken(in text: String, matchRange: NSRange) -> Bool {
    if matchRange.location == 0 {
        return true
    }

    let nsText = text as NSString
    var index = matchRange.location - 1

    while index >= 0 {
        let previous = nsText.substring(with: NSRange(location: index, length: 1))
        if previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index -= 1
            continue
        }

        return previous == "." || previous == "!" || previous == "?" || previous == "\n" || previous == ":" || previous == ";"
    }

    return true
}

private func isLikelyInternalUIToken(_ token: String) -> Bool {
    if token.hasPrefix("_") {
        return true
    }

    let internalPrefixes = ["NS", "SF", "AX", "UI", "WK", "CG", "CF", "MTK"]
    for prefix in internalPrefixes where token.hasPrefix(prefix) && token.count > prefix.count + 3 {
        if token.contains(where: { $0.isUppercase }) {
            return true
        }
    }

    let internalSuffixes = [
        "View", "Window", "Controller", "Editor", "Split", "Scroll", "Cell",
        "Button", "Field", "Toolbar", "Outline", "Table", "Collection", "Detached"
    ]
    for suffix in internalSuffixes where token.hasSuffix(suffix) {
        return true
    }

    return false
}
