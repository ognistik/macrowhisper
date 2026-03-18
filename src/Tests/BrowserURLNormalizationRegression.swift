import Foundation

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    if !condition {
        let suffix = details.isEmpty ? "" : "\n\(details)"
        fputs("FAIL: \(label)\(suffix)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runBrowserURLNormalizationRegressionTests() {
    let truncatedCommandBarHost = normalizeArcCommandBarURLCandidate("resources.arc.net")
    assertTrue(
        truncatedCommandBarHost == nil,
        "Arc command bar host-only value is rejected"
    )

    let fullCommandBarURL = normalizeArcCommandBarURLCandidate("resources.arc.net/hc/en-us/articles/123?ref=abc")
    assertTrue(
        fullCommandBarURL == "https://resources.arc.net/hc/en-us/articles/123?ref=abc",
        "Arc command bar full URL with path/query is normalized"
    )

    let trustedWebAreaOrigin = normalizeBrowserURLCandidate("https://resources.arc.net")
    assertTrue(
        trustedWebAreaOrigin == "https://resources.arc.net",
        "Web area origin-only URL remains valid"
    )

    let invalidCandidate = normalizeBrowserURLCandidate("search terms")
    assertTrue(
        invalidCandidate == nil,
        "Invalid URL-like text is rejected"
    )

    let urlObjectCandidate = normalizeBrowserURLCandidate(URL(string: "https://resources.arc.net/docs")!)
    assertTrue(
        urlObjectCandidate == "https://resources.arc.net/docs",
        "URL object candidates are normalized"
    )

    let originDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com",
        attribute: "AXValue",
        role: "AXTextField",
        depth: 2,
        discoveryIndex: 0
    )
    let subpageDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com/docs/getting-started",
        attribute: "AXValue",
        role: "AXTextField",
        depth: 3,
        discoveryIndex: 5
    )
    assertTrue(
        shouldPreferBrowserURLCandidate(subpageDescriptor, over: originDescriptor),
        "More specific subpage beats origin-only candidate"
    )

    let axValueDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com/docs",
        attribute: "AXValue",
        role: "AXTextField",
        depth: 2,
        discoveryIndex: 0
    )
    let axURLDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com/docs",
        attribute: "AXURL",
        role: "AXTextField",
        depth: 2,
        discoveryIndex: 1
    )
    assertTrue(
        shouldPreferBrowserURLCandidate(axURLDescriptor, over: axValueDescriptor),
        "AXURL beats AXValue at equal specificity"
    )

    let chromeDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com/docs",
        attribute: "AXURL",
        role: "AXTextField",
        depth: 1,
        discoveryIndex: 0
    )
    let webAreaDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com/docs",
        attribute: "AXURL",
        role: "AXWebArea",
        depth: 4,
        discoveryIndex: 3
    )
    assertTrue(
        shouldPreferBrowserURLCandidate(webAreaDescriptor, over: chromeDescriptor),
        "AXWebArea beats chrome text field at equal specificity"
    )

    let earlierOriginDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com",
        attribute: "AXURL",
        role: "AXWebArea",
        depth: 1,
        discoveryIndex: 0
    )
    let laterSpecificDescriptor = BrowserURLCandidateDescriptor(
        normalizedURL: "https://example.com/docs?ref=abc",
        attribute: "AXValue",
        role: "AXTextField",
        depth: 5,
        discoveryIndex: 20
    )
    assertTrue(
        shouldPreferBrowserURLCandidate(laterSpecificDescriptor, over: earlierOriginDescriptor),
        "Later candidate replaces earlier candidate when specificity is higher"
    )

    let cacheIdentity = BrowserURLCacheIdentity(appPid: 42, windowHash: 99)
    assertTrue(
        shouldReuseBrowserURLCacheEntry(
            entryIdentity: cacheIdentity,
            requestedIdentity: cacheIdentity,
            age: 1.0,
            ttl: 2.0
        ),
        "Cache entry is reusable for same window within TTL"
    )

    assertTrue(
        !shouldReuseBrowserURLCacheEntry(
            entryIdentity: cacheIdentity,
            requestedIdentity: BrowserURLCacheIdentity(appPid: 42, windowHash: 100),
            age: 0.5,
            ttl: 2.0
        ),
        "Window change invalidates browser URL cache reuse"
    )

    assertTrue(
        browserURLCacheReplayDisposition(normalizedURL: nil) == .invalidate,
        "Failed cache replay invalidates the cache entry"
    )
}

@main
struct BrowserURLNormalizationRegressionRunner {
    static func main() {
        runBrowserURLNormalizationRegressionTests()
    }
}
