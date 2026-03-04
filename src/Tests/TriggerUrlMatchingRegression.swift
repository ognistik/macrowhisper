import Foundation

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    if !condition {
        let suffix = details.isEmpty ? "" : "\n\(details)"
        fputs("FAIL: \(label)\(suffix)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func makeInsert(
    triggerVoice: String? = nil,
    triggerUrls: String? = nil,
    triggerLogic: String? = "or"
) -> AppConfiguration.Insert {
    AppConfiguration.Insert(
        triggerVoice: triggerVoice,
        triggerApps: nil,
        triggerModes: nil,
        triggerUrls: triggerUrls,
        triggerLogic: triggerLogic
    )
}

private func matchedInsertNames(
    inserts: [String: AppConfiguration.Insert],
    result: String = "",
    frontAppUrl: String?
) -> [String] {
    let config = AppConfiguration(inserts: inserts)
    let manager = ConfigurationManager(config: config)
    let evaluator = TriggerEvaluator(logger: Logger())
    let matches = evaluator.evaluateTriggersForAllActions(
        configManager: manager,
        result: result,
        metaJson: [:],
        frontAppName: nil,
        frontAppBundleId: nil,
        frontAppUrl: frontAppUrl
    )
    return matches.filter { $0.type == .insert }.map { $0.name }
}

private func runTriggerUrlMatchingRegressionTests() {
    do {
        let matches1 = matchedInsertNames(
            inserts: ["domain": makeInsert(triggerUrls: "google.com")],
            frontAppUrl: "https://docs.google.com/maps?q=test"
        )
        assertTrue(matches1.contains("domain"), "domain token matches subdomain + path")

        let matches2 = matchedInsertNames(
            inserts: ["www": makeInsert(triggerUrls: "www.google.com")],
            frontAppUrl: "https://maps.google.com"
        )
        assertTrue(!matches2.contains("www"), "www host token does not match sibling subdomain")

        let matches3 = matchedInsertNames(
            inserts: ["nested": makeInsert(triggerUrls: "www.google.com")],
            frontAppUrl: "https://x.www.google.com"
        )
        assertTrue(matches3.contains("nested"), "www host token matches deeper www-prefixed subdomain")

        let matches4 = matchedInsertNames(
            inserts: ["strict": makeInsert(triggerUrls: "https://google.com")],
            frontAppUrl: "http://google.com/maps"
        )
        assertTrue(matches4.contains("strict"), "full URL token ignores scheme but keeps strict host")

        let matches5 = matchedInsertNames(
            inserts: ["strict": makeInsert(triggerUrls: "https://google.com")],
            frontAppUrl: "https://docs.google.com/maps"
        )
        assertTrue(!matches5.contains("strict"), "full URL token does not match other subdomains")

        let matches6 = matchedInsertNames(
            inserts: ["path": makeInsert(triggerUrls: "https://www.google.com/other")],
            frontAppUrl: "https://www.google.com/other/path?x=1"
        )
        assertTrue(matches6.contains("path"), "full URL token path prefix matches")

        let matches7 = matchedInsertNames(
            inserts: ["path": makeInsert(triggerUrls: "https://www.google.com/other")],
            frontAppUrl: "https://www.google.com/maps"
        )
        assertTrue(!matches7.contains("path"), "full URL token path prefix filters non-matching paths")

        let matches8 = matchedInsertNames(
            inserts: ["except": makeInsert(triggerUrls: "google.com|!mail.google.com")],
            frontAppUrl: "https://mail.google.com"
        )
        assertTrue(!matches8.contains("except"), "exceptions override positives")

        let matches9 = matchedInsertNames(
            inserts: ["exceptOnly": makeInsert(triggerUrls: "!mail.google.com")],
            frontAppUrl: "https://docs.google.com"
        )
        assertTrue(matches9.contains("exceptOnly"), "exception-only token matches when exception is absent")

        let matches10 = matchedInsertNames(
            inserts: ["exceptOnly": makeInsert(triggerUrls: "!mail.google.com")],
            frontAppUrl: nil
        )
        assertTrue(!matches10.contains("exceptOnly"), "URL trigger does not match when active URL is unavailable")

        let matches11 = matchedInsertNames(
            inserts: ["and": makeInsert(triggerVoice: "search", triggerUrls: "google.com", triggerLogic: "and")],
            result: "search best keyboard",
            frontAppUrl: "https://docs.google.com"
        )
        assertTrue(matches11.contains("and"), "AND logic requires both voice and URL conditions")

        let matches12 = matchedInsertNames(
            inserts: ["and": makeInsert(triggerVoice: "search", triggerUrls: "google.com", triggerLogic: "and")],
            result: "search best keyboard",
            frontAppUrl: "https://example.com"
        )
        assertTrue(!matches12.contains("and"), "AND logic fails when URL condition fails")

        let matches13 = matchedInsertNames(
            inserts: ["or": makeInsert(triggerVoice: "search", triggerUrls: "google.com", triggerLogic: "or")],
            result: "compose email",
            frontAppUrl: "https://docs.google.com"
        )
        assertTrue(matches13.contains("or"), "OR logic matches when URL condition alone succeeds")

        let matches14 = matchedInsertNames(
            inserts: ["invalidSkipped": makeInsert(triggerUrls: "*google.com|google.com")],
            frontAppUrl: "https://docs.google.com"
        )
        assertTrue(matches14.contains("invalidSkipped"), "invalid URL token is skipped when another valid token matches")

        let matches15 = matchedInsertNames(
            inserts: ["invalidOnly": makeInsert(triggerUrls: "*google.com")],
            frontAppUrl: "https://docs.google.com"
        )
        assertTrue(!matches15.contains("invalidOnly"), "invalid-only URL trigger does not match")
    }
}

@main
struct TriggerUrlMatchingRegressionRunner {
    static func main() {
        runTriggerUrlMatchingRegressionTests()
    }
}
