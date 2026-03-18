import Foundation

enum BrowserURLSpecificity: Int, Comparable {
    case originOnly = 0
    case path = 1
    case pathQueryOrFragment = 2

    var logLabel: String {
        switch self {
        case .originOnly:
            return "originOnly"
        case .path:
            return "path"
        case .pathQueryOrFragment:
            return "path+query/fragment"
        }
    }

    static func < (lhs: BrowserURLSpecificity, rhs: BrowserURLSpecificity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BrowserURLCandidateDescriptor {
    let normalizedURL: String
    let specificity: BrowserURLSpecificity
    let attribute: String
    let role: String
    let depth: Int
    let discoveryIndex: Int

    init(
        normalizedURL: String,
        attribute: String,
        role: String,
        depth: Int,
        discoveryIndex: Int,
        specificity: BrowserURLSpecificity? = nil
    ) {
        self.normalizedURL = normalizedURL
        self.specificity = specificity ?? browserURLSpecificity(for: normalizedURL)
        self.attribute = attribute
        self.role = role
        self.depth = depth
        self.discoveryIndex = discoveryIndex
    }
}

struct BrowserURLCacheIdentity: Equatable {
    let appPid: Int32
    let windowHash: Int
}

enum BrowserURLCacheReplayDisposition {
    case useValue
    case invalidate
}

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

func browserURLSpecificity(for normalizedURL: String) -> BrowserURLSpecificity {
    guard let components = URLComponents(string: normalizedURL) else {
        return .originOnly
    }

    let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasMeaningfulPath = !path.isEmpty && path != "/"
    let hasQuery = !(components.percentEncodedQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    let hasFragment = !(components.percentEncodedFragment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

    if hasQuery || hasFragment {
        return .pathQueryOrFragment
    }
    if hasMeaningfulPath {
        return .path
    }
    return .originOnly
}

func shouldPreferBrowserURLCandidate(
    _ candidate: BrowserURLCandidateDescriptor,
    over current: BrowserURLCandidateDescriptor
) -> Bool {
    if candidate.specificity != current.specificity {
        return candidate.specificity > current.specificity
    }

    let candidateAttributePreference = browserURLAttributePreferenceScore(candidate.attribute)
    let currentAttributePreference = browserURLAttributePreferenceScore(current.attribute)
    if candidateAttributePreference != currentAttributePreference {
        return candidateAttributePreference > currentAttributePreference
    }

    let candidateRolePreference = browserURLRolePreferenceScore(candidate.role)
    let currentRolePreference = browserURLRolePreferenceScore(current.role)
    if candidateRolePreference != currentRolePreference {
        return candidateRolePreference > currentRolePreference
    }

    if candidate.depth != current.depth {
        return candidate.depth < current.depth
    }

    if candidate.discoveryIndex != current.discoveryIndex {
        return candidate.discoveryIndex < current.discoveryIndex
    }

    return false
}

func shouldReuseBrowserURLCacheEntry(
    entryIdentity: BrowserURLCacheIdentity,
    requestedIdentity: BrowserURLCacheIdentity,
    age: TimeInterval,
    ttl: TimeInterval
) -> Bool {
    guard entryIdentity == requestedIdentity else {
        return false
    }
    return age <= ttl
}

func browserURLCacheReplayDisposition(normalizedURL: String?) -> BrowserURLCacheReplayDisposition {
    normalizedURL == nil ? .invalidate : .useValue
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

private func browserURLAttributePreferenceScore(_ attribute: String) -> Int {
    switch attribute {
    case "AXURL":
        return 4
    case "AXDocument":
        return 3
    case "AXValue":
        return 2
    case "AXPlaceholderValue":
        return 1
    default:
        return 0
    }
}

private func browserURLRolePreferenceScore(_ role: String) -> Int {
    switch role {
    case "AXWebArea":
        return 3
    case "AXSearchField":
        return 2
    case "AXTextField", "AXComboBox":
        return 1
    default:
        return 0
    }
}
