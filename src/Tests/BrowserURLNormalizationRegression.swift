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
}

@main
struct BrowserURLNormalizationRegressionRunner {
    static func main() {
        runBrowserURLNormalizationRegressionTests()
    }
}
