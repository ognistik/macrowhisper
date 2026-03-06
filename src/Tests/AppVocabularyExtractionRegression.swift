import Foundation

private func assertContains(_ tokens: [String], _ expected: String, _ label: String) {
    if !tokens.contains(expected) {
        fputs("FAIL: \(label)\nmissing token: \(expected)\nactual: \(tokens)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertNotContains(_ tokens: [String], _ unexpected: String, _ label: String) {
    if tokens.contains(unexpected) {
        fputs("FAIL: \(label)\nunexpected token: \(unexpected)\nactual: \(tokens)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runAppVocabularyExtractionRegressionTests() {
    let dictatedTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "Please update Postgres render with SwiftUI. Then run render with pytest and OpenAI. Later pytest records failures.",
                source: "value"
            )
        ],
        isInputFocused: true
    )
    assertContains(dictatedTokens, "Postgres", "dictation keeps capitalized technical term")
    assertContains(dictatedTokens, "SwiftUI", "dictation keeps mixed-case framework name")
    assertContains(dictatedTokens, "render", "dictation keeps repeated lowercase technical term")
    assertContains(dictatedTokens, "pytest", "dictation keeps lowercase tool term")
    assertContains(dictatedTokens, "OpenAI", "dictation keeps organization-style token")
    assertNotContains(dictatedTokens, "Please", "dictation drops sentence-start noise")
    assertNotContains(dictatedTokens, "Then", "dictation drops later sentence-start noise")

    let uiHeavyTokens = extractVocabularyTokensForTesting(
        snippets: [
            (text: "Open Close Window Section", source: "label"),
            (text: "AcmeDashboard", source: "title"),
            (text: "AcmeDashboard workspace summary", source: "description")
        ]
    )
    assertContains(uiHeavyTokens, "AcmeDashboard", "ui-heavy content keeps repeated app term")
    assertNotContains(uiHeavyTokens, "Open", "ui-heavy content drops generic open")
    assertNotContains(uiHeavyTokens, "Close", "ui-heavy content drops generic close")
    assertNotContains(uiHeavyTokens, "Window", "ui-heavy content drops generic window")
    assertNotContains(uiHeavyTokens, "Section", "ui-heavy content drops generic section")

    let codeTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "Use fetchData(), userId, Result<T>, @State, :hover, and --model for styling.",
                source: "value"
            )
        ],
        isInputFocused: true
    )
    assertContains(codeTokens, "fetchData", "code-like content keeps function token")
    assertContains(codeTokens, "userId", "code-like content keeps variable token")
    assertContains(codeTokens, "Result", "code-like content keeps generic type token")
    assertContains(codeTokens, "State", "code-like content keeps property-wrapper token")
    assertContains(codeTokens, "hover", "code-like content keeps pseudo-selector token")
    assertContains(codeTokens, "--model", "code-like content keeps CLI flag token")

    let browserTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "When OpenAI published the article, Anthropic reviewed the benchmark. OpenAI discussed the benchmark again.",
                source: "description"
            )
        ],
        isBrowserApp: true
    )
    assertContains(browserTokens, "OpenAI", "browser prose keeps repeated organization name")
    assertContains(browserTokens, "Anthropic", "browser prose keeps organization name")
    assertContains(browserTokens, "benchmark", "browser prose keeps repeated domain term")
    assertNotContains(browserTokens, "When", "browser prose drops sentence-start filler")

    let editorTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "The websocket pipeline sends websocket frames, and websocket retries matter.",
                source: "value"
            )
        ],
        isInputFocused: true
    )
    assertContains(editorTokens, "websocket", "editor prose keeps repeated lowercase domain term")
    assertNotContains(editorTokens, "The", "editor prose drops sentence-start article")

    let contractionTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "I haven't finished the smartclip setup because it hasn't synced with Macrowhisper yet.",
                source: "value"
            )
        ],
        isInputFocused: true
    )
    assertContains(contractionTokens, "smartclip", "contraction text keeps repeated technical term")
    assertContains(contractionTokens, "Macrowhisper", "contraction text keeps product name")
    assertNotContains(contractionTokens, "haven", "contraction text drops haven fragment")
    assertNotContains(contractionTokens, "hasn", "contraction text drops hasn fragment")

    let duplicateSourceTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "Just add one thing and couple details before you run it.",
                source: "value"
            ),
            (
                text: "Just add one thing and couple details before you run it.",
                source: "description"
            )
        ],
        isInputFocused: true
    )
    assertNotContains(duplicateSourceTokens, "Just", "duplicate source text does not elevate sentence-start filler")
    assertNotContains(duplicateSourceTokens, "thing", "duplicate source text does not elevate generic noun")
    assertNotContains(duplicateSourceTokens, "couple", "duplicate source text does not elevate generic quantity word")
    assertNotContains(duplicateSourceTokens, "details", "duplicate source text does not elevate generic noun via duplicate AX paths")

    let codexStyleTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "Reduce sentence-start noise in AppVocabulary.swift. Relax the lowercase gate, preserve async props and postgres, and explain why identifier-shaped tokens survive while Create and Expand are generic prose.",
                source: "description"
            )
        ]
    )
    assertContains(codexStyleTokens, "AppVocabulary", "codex-style text keeps mixed-case technical symbol")
    assertContains(codexStyleTokens, "AppVocabulary.swift", "codex-style text keeps file-like technical term")
    assertContains(codexStyleTokens, "async", "codex-style text keeps lowercase technical term in technical context")
    assertContains(codexStyleTokens, "postgres", "codex-style text keeps lowercase domain term in technical context")
    assertContains(codexStyleTokens, "identifier-shaped", "codex-style text keeps hyphenated technical phrase")
    assertNotContains(codexStyleTokens, "Reduce", "codex-style text drops imperative sentence opener")
    assertNotContains(codexStyleTokens, "Relax", "codex-style text drops second imperative opener")
    assertNotContains(codexStyleTokens, "Create", "codex-style text drops later title-cased generic verb")
    assertNotContains(codexStyleTokens, "Expand", "codex-style text drops title-cased generic prose word")

    let appStyleTokens = extractVocabularyTokensForTesting(
        snippets: [
            (
                text: "Macrowhisper and Superwhisper use clipboardContext with BetterTouchTool. Bear and Raycast support --add-insert and --copy-action, but add one outline feature and capture the result during recording.",
                source: "value"
            )
        ],
        isInputFocused: true
    )
    assertContains(appStyleTokens, "Macrowhisper", "app-style text keeps product name")
    assertContains(appStyleTokens, "Superwhisper", "app-style text keeps second product name")
    assertContains(appStyleTokens, "clipboardContext", "app-style text keeps camelCase placeholder")
    assertContains(appStyleTokens, "BetterTouchTool", "app-style text keeps mixed-case app name")
    assertContains(appStyleTokens, "--add-insert", "app-style text keeps CLI flag")
    assertContains(appStyleTokens, "--copy-action", "app-style text keeps second CLI flag")
    assertContains(appStyleTokens, "Bear", "app-style text keeps app name")
    assertContains(appStyleTokens, "Raycast", "app-style text keeps second app name")
    assertNotContains(appStyleTokens, "add", "app-style text drops generic verb")
    assertNotContains(appStyleTokens, "outline", "app-style text drops generic noun")
    assertNotContains(appStyleTokens, "feature", "app-style text drops generic feature word")
    assertNotContains(appStyleTokens, "capture", "app-style text drops generic capture word")
    assertNotContains(appStyleTokens, "result", "app-style text drops generic result word")
    assertNotContains(appStyleTokens, "recording", "app-style text drops generic recording word")
}

@main
struct AppVocabularyExtractionRegressionRunner {
    static func main() {
        runAppVocabularyExtractionRegressionTests()
    }
}
