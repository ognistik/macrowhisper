import Foundation

func normalizeBrowserURLCandidate(_ rawValue: Any?) -> String? {
    let text: String
    if let stringValue = rawValue as? String {
        text = stringValue
    } else if let urlValue = rawValue as? URL {
        text = urlValue.absoluteString
    } else {
        return nil
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalizedInput: String
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
        normalizedInput = trimmed
    } else {
        normalizedInput = "https://\(trimmed)"
    }

    guard let components = URLComponents(string: normalizedInput),
          let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty else {
        return nil
    }

    return components.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalizedInput
}

func arcCommandBarURLContainsPathOrQuery(_ normalizedURL: String) -> Bool {
    guard let components = URLComponents(string: normalizedURL) else {
        return false
    }

    let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasMeaningfulPath = !path.isEmpty && path != "/"
    let hasQuery = !(components.percentEncodedQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    let hasFragment = !(components.percentEncodedFragment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    return hasMeaningfulPath || hasQuery || hasFragment
}

func normalizeArcCommandBarURLCandidate(_ rawValue: Any?) -> String? {
    guard let normalizedURL = normalizeBrowserURLCandidate(rawValue) else {
        return nil
    }

    guard arcCommandBarURLContainsPathOrQuery(normalizedURL) else {
        return nil
    }

    return normalizedURL
}
