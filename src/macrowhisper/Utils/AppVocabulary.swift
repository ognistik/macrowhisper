import ApplicationServices
import Cocoa
import NaturalLanguage

private let appVocabularyMaxTraversalDepth = 4 //Used in tree crawl
private let appVocabularyMaxVisitedNodes = 360 //Hard cap on AX elements visited
private let appVocabularyMaxSnippets = 460 //text chunks/groups
private let appVocabularyMaxSnippetLength = 320 //snippet length outside .value (non-input fields)
private let appVocabularyMaxLongTextSnippetLength = 2600 //long descriptive text (titles/descriptions/help)
private let appVocabularyMaxValueSnippetLength = 4000 //snippet length inside .value (input fields)
private let appVocabularyMaxOutputTokens = 400 //total output terms after filtering and rules

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

private let axTraversalChildAttributes: [CFString] = [
    kAXChildrenAttribute as CFString,
    "AXContents" as CFString,
    "AXVisibleChildren" as CFString,
    "AXChildrenInNavigationOrder" as CFString
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
func getAppVocabulary(targetPid: Int32? = nil, fallbackAppName: String? = nil, fallbackBundleId: String? = nil) -> String {
    guard AXIsProcessTrusted() else {
        logDebug("[AppVocabulary] No accessibility permissions, cannot get app vocabulary")
        return ""
    }

    guard let targetApp = resolveVocabularyTargetApp(targetPid: targetPid) else {
        logDebug("[AppVocabulary] No target application found")
        return ""
    }

    let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
    var snippets: [VocabularySnippet] = []
    let directInputContent = getInputFieldContent(appElement: appElement)
    let hasDirectInputContent = !(directInputContent?.isEmpty ?? true)
    let appBundleId = targetApp.bundleIdentifier ?? fallbackBundleId ?? ""
    let isBrowserApp = appVocabularyBrowserBundleIds.contains(appBundleId)

    let appName = targetApp.localizedName ?? fallbackAppName ?? ""
    if !appName.isEmpty {
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
                if let webArea = findBestWebArea(from: windowElement, maxDepth: 10, maxNodes: 2200) {
                    let mergedWebText = buildBrowserWebContentSample(from: webArea, maxCharacters: 12000)
                    if !mergedWebText.isEmpty {
                        let cleaned = normalizeVocabularySnippet(mergedWebText, source: .description)
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

private func resolveVocabularyTargetApp(targetPid: Int32?) -> NSRunningApplication? {
    if let targetPid {
        if let app = NSRunningApplication(processIdentifier: targetPid), !app.isTerminated {
            return app
        }
    }
    return NSWorkspace.shared.frontmostApplication
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

        let children = getAXTraversalChildren(of: element)
        if !children.isEmpty {
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
    return findElements(withRole: targetRole, from: root, maxDepth: maxDepth, maxNodes: maxNodes, maxResults: 1).first
}

func findElements(withRole targetRole: String, from root: AXUIElement, maxDepth: Int, maxNodes: Int, maxResults: Int) -> [AXUIElement] {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var visited = 0
    var results: [AXUIElement] = []

    while index < queue.count, visited < maxNodes {
        let (element, depth) = queue[index]
        index += 1
        visited += 1

        if getAXRole(of: element) == targetRole {
            results.append(element)
            if results.count >= maxResults {
                break
            }
        }

        if depth >= maxDepth {
            continue
        }

        let children = getAXTraversalChildren(of: element)
        if !children.isEmpty {
            for child in children {
                queue.append((child, depth + 1))
            }
        }
    }

    return results
}

func findBestWebArea(from root: AXUIElement, maxDepth: Int, maxNodes: Int) -> AXUIElement? {
    let candidates = findElements(withRole: "AXWebArea", from: root, maxDepth: maxDepth, maxNodes: maxNodes, maxResults: 20)
    guard !candidates.isEmpty else { return nil }

    var bestElement: AXUIElement?
    var bestScore = Int.min

    for webArea in candidates {
        let charCount = getAXNumberOfCharacters(webArea) ?? 0
        var score = charCount

        if score <= 0 {
            if let parameterizedText = extractWebAreaParameterizedText(webArea, maxCharacters: 1200) {
                score = max(score, parameterizedText.count)
            }
        }

        if score <= 0 {
            let snippets = collectVocabularySnippets(
                from: webArea,
                maxDepth: 4,
                maxNodes: 260,
                maxSnippets: 120
            )
            let snippetChars = snippets.reduce(0) { partial, snippet in
                partial + snippet.text.count
            }
            score = max(score, snippetChars)
        }

        if bestElement == nil || score > bestScore {
            bestElement = webArea
            bestScore = score
        }
    }

    return bestElement ?? candidates.first
}

func getAXTraversalChildren(of element: AXUIElement) -> [AXUIElement] {
    var children: [AXUIElement] = []
    var seen = Set<CFHashCode>()

    for attribute in axTraversalChildAttributes {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value = value else { continue }

        if let arrayChildren = value as? [AXUIElement] {
            for child in arrayChildren {
                let childHash = CFHash(child)
                if seen.insert(childHash).inserted {
                    children.append(child)
                }
            }
        } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
            let singleChild = unsafeBitCast(value, to: AXUIElement.self)
            let childHash = CFHash(singleChild)
            if seen.insert(childHash).inserted {
                children.append(singleChild)
            }
        }
    }

    return children
}

func buildBrowserWebContentSample(from webArea: AXUIElement, maxCharacters: Int) -> String {
    var candidateWebAreas: [AXUIElement] = [webArea]
    let nestedCandidates = findElements(withRole: "AXWebArea", from: webArea, maxDepth: 10, maxNodes: 4000, maxResults: 40)
    for candidate in nestedCandidates {
        let hash = CFHash(candidate)
        let alreadyIncluded = candidateWebAreas.contains { CFHash($0) == hash }
        if !alreadyIncluded {
            candidateWebAreas.append(candidate)
        }
    }
    if candidateWebAreas.isEmpty {
        candidateWebAreas = [webArea]
    }

    var chunks: [String] = []
    for candidate in candidateWebAreas {
        if let parameterizedText = extractWebAreaParameterizedText(candidate, maxCharacters: maxCharacters * 2),
           !parameterizedText.isEmpty {
            chunks.append(parameterizedText)
        }
        if let deepText = collectWebReadableText(from: candidate, maxDepth: 40, maxNodes: 5000, maxCharacters: maxCharacters * 2),
           !deepText.isEmpty {
            chunks.append(deepText)
        }
    }

    if !chunks.isEmpty {
        let merged = mergeTextChunks(chunks, maxCharacters: maxCharacters)
        if !merged.isEmpty {
            return merged
        }
    }

    let contentRoot = findBestWebArea(from: webArea, maxDepth: 8, maxNodes: 2200) ?? webArea
    let snippets = collectVocabularySnippets(
        from: contentRoot,
        maxDepth: 12,
        maxNodes: 3000,
        maxSnippets: 1800
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

private func mergeTextChunks(_ chunks: [String], maxCharacters: Int) -> String {
    let ordered = chunks.sorted { $0.count > $1.count }
    var seen = Set<String>()
    var parts: [String] = []
    var currentLength = 0

    for chunk in ordered {
        let lines = chunk
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }

        for line in lines {
            guard !seen.contains(line) else { continue }
            seen.insert(line)

            let separator = parts.isEmpty ? 0 : 1
            if currentLength + separator + line.count > maxCharacters {
                return parts.joined(separator: "\n")
            }

            parts.append(line)
            currentLength += separator + line.count
        }
    }

    return parts.joined(separator: "\n")
}

private func collectWebReadableText(from root: AXUIElement, maxDepth: Int, maxNodes: Int, maxCharacters: Int) -> String? {
    let rolePreference: Set<String> = [
        "AXStaticText",
        "AXLink",
        "AXHeading",
        "AXTextArea",
        "AXCell",
        "AXListItem",
        "AXRow",
        "AXButton"
    ]
    let textAttributes: [CFString] = [
        kAXValueAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString,
        "AXLabel" as CFString
    ]

    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var visited = 0
    var pieces: [String] = []
    var seen = Set<String>()
    var currentLength = 0

    while index < queue.count && visited < maxNodes && currentLength < maxCharacters {
        let (element, depth) = queue[index]
        index += 1
        visited += 1

        let role = getAXRole(of: element)
        let shouldExtract = role == nil || rolePreference.contains(role!)
        if shouldExtract {
            for attribute in textAttributes {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, attribute, &value)
                guard error == .success, let value = value else { continue }

                let texts = extractTextValuesFromAXAttribute(value)
                for text in texts {
                    let compact = text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    guard !compact.isEmpty else { continue }
                    guard !seen.contains(compact) else { continue }
                    seen.insert(compact)

                    let separator = pieces.isEmpty ? 0 : 1
                    if currentLength + separator + compact.count > maxCharacters {
                        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
                    }

                    pieces.append(compact)
                    currentLength += separator + compact.count
                }
            }
        }

        if depth < maxDepth {
            let children = getAXTraversalChildren(of: element)
            if !children.isEmpty {
                for child in children {
                    queue.append((child, depth + 1))
                    if queue.count >= (maxNodes * 2) {
                        break
                    }
                }
            }
        }
    }

    return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
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
    if let count = getAXNumberOfCharacters(webArea) {
        return CFRange(location: 0, length: max(0, count))
    }
    return nil
}

private func getAXNumberOfCharacters(_ element: AXUIElement) -> Int? {
    var charactersValue: CFTypeRef?
    let countError = AXUIElementCopyAttributeValue(element, "AXNumberOfCharacters" as CFString, &charactersValue)
    guard countError == .success,
          let number = charactersValue as? NSNumber else {
        return nil
    }
    return number.intValue
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

// treat newline, or a period followed by whitespace (space/return/tab etc.) as sentence start
func isLikelySentenceStartToken(in text: String, matchRange: NSRange) -> Bool {
    guard matchRange.location != 0 else { return true }

    let nsText = text as NSString
    var idx = matchRange.location - 1

    // back-skip whitespace to find the *true* preceding character
    while idx >= 0 {
        let char = nsText.substring(with: NSRange(location: idx, length: 1)).utf16.first!
        if CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(char)!) {
            idx -= 1
            continue
        }
        break
    }
    guard idx >= 0 else { return true } // nothing but whitespace
    let prev = nsText.substring(with: NSRange(location: idx, length: 1))
    return ([".", "!", "?", ":", ";"].contains(prev)) ||
           prev.rangeOfCharacter(from: CharacterSet.newlines) != nil
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
