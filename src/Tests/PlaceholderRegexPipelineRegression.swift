import Foundation

private func assertEqual(_ actual: String, _ expected: String, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertTrue(_ condition: Bool, _ label: String, details: String) {
    if !condition {
        fputs("FAIL: \(label)\n\(details)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runPlaceholderRegexPipelineRegressionTests() {
    do {
        let action1 = "{{swResult||(?s)(.*)||${1}}}"
        let meta1: [String: Any] = ["llmResult": "hello world"]
        let result1 = processDynamicPlaceholders(action: action1, metaJson: meta1, actionType: .insert).text
        assertEqual(result1, "hello world", "brace capture reference ${1} in placeholder regex replacement")

        let action2 = "{{swResult::ensureSentence||(?s)(.*)||${1::lowercase}}}"
        let meta2: [String: Any] = ["llmResult": "HELLO WORLD"]
        let result2 = processDynamicPlaceholders(action: action2, metaJson: meta2, actionType: .insert).text
        assertEqual(result2, "hello world.", "transform + capture-scoped transform in same placeholder")

        let action3 = "{{swResult||foo||{bar}}}"
        let meta3: [String: Any] = ["llmResult": "foo"]
        let result3 = processDynamicPlaceholders(action: action3, metaJson: meta3, actionType: .insert).text
        assertEqual(result3, "{bar}", "replacement ending in brace does not break placeholder closing")

        let action4 = "{{swResult||([0-9]+)||{${1}}}}"
        let meta4: [String: Any] = ["llmResult": "abc123"]
        let result4 = processDynamicPlaceholders(action: action4, metaJson: meta4, actionType: .insert).text
        assertEqual(result4, "abc{123}", "nested brace + capture template remains parse-safe")

        let action5 = "{{swResult||([A-Z]+)||${1::doesNotExist}}}"
        let meta5: [String: Any] = ["llmResult": "ABC"]
        let result5 = processDynamicPlaceholders(action: action5, metaJson: meta5, actionType: .insert).text
        assertEqual(result5, "ABC", "unknown capture transform fails open")

        let action6 = "{{swResult::titleCase:fr}}"
        let meta6: [String: Any] = ["llmResult": "le seigneur des anneaux et l'amour perdu"]
        let result6 = processDynamicPlaceholders(action: action6, metaJson: meta6, actionType: .insert).text
        assertEqual(result6, "Le Seigneur des Anneaux et l'amour Perdu", "explicit French title case applies minor word rules")

        let action7 = "{{swResult::titleCase}}"
        let meta7: [String: Any] = ["llmResult": "l'été en provence et le chant du vent"]
        let result7 = processDynamicPlaceholders(action: action7, metaJson: meta7, actionType: .insert).text
        assertEqual(result7, "L'été en Provence et le Chant du Vent", "auto title case detects French")

        let action8 = "{{swResult::titleCase}}"
        let meta8: [String: Any] = ["llmResult": "la sopa de pollo"]
        let result8 = processDynamicPlaceholders(action: action8, metaJson: meta8, actionType: .insert).text
        assertEqual(result8, "La Sopa de Pollo", "auto title case preserves Spanish minor words in romance tie cases")

        let action9 = "{{swResult::camelCase}}"
        let meta9: [String: Any] = ["llmResult": "hello_world HTTP server"]
        let result9 = processDynamicPlaceholders(action: action9, metaJson: meta9, actionType: .insert).text
        assertEqual(result9, "helloWorldHttpServer", "camelCase handles delimiters and acronym chunks")

        let action10 = "{{swResult::pascalCase}}"
        let meta10: [String: Any] = ["llmResult": "hello_world HTTP server"]
        let result10 = processDynamicPlaceholders(action: action10, metaJson: meta10, actionType: .insert).text
        assertEqual(result10, "HelloWorldHttpServer", "pascalCase capitalizes all word tokens")

        let action11 = "{{swResult::snakeCase}}"
        let meta11: [String: Any] = ["llmResult": "helloWorld HTTPServer now"]
        let result11 = processDynamicPlaceholders(action: action11, metaJson: meta11, actionType: .insert).text
        assertEqual(result11, "hello_world_http_server_now", "snakeCase tokenizes camel/pascal words")

        let action12 = "{{swResult::kebabCase}}"
        let meta12: [String: Any] = ["llmResult": "helloWorld HTTPServer now"]
        let result12 = processDynamicPlaceholders(action: action12, metaJson: meta12, actionType: .insert).text
        assertEqual(result12, "hello-world-http-server-now", "kebabCase tokenizes camel/pascal words")

        let action13 = "{{swResult::altCase}}"
        let meta13: [String: Any] = ["llmResult": "hello world"]
        let result13 = processDynamicPlaceholders(action: action13, metaJson: meta13, actionType: .insert).text
        assertEqual(result13, "hElLo WoRlD", "altCase starts lowercase")

        let action14 = "{{swResult::altCase:upperFirst}}"
        let meta14: [String: Any] = ["llmResult": "hello world"]
        let result14 = processDynamicPlaceholders(action: action14, metaJson: meta14, actionType: .insert).text
        assertEqual(result14, "HeLlO wOrLd", "altCase:upperFirst starts uppercase")

        let action15 = "{{swResult::trim}}"
        let meta15: [String: Any] = ["llmResult": " \n\t hello world \n\n"]
        let result15 = processDynamicPlaceholders(action: action15, metaJson: meta15, actionType: .insert).text
        assertEqual(result15, "hello world", "trim removes edge whitespace/newlines only")

        let action16 = "{{swResult::randomCase}}"
        let meta16: [String: Any] = ["llmResult": "hello-world 123"]
        let result16 = processDynamicPlaceholders(action: action16, metaJson: meta16, actionType: .insert).text
        assertTrue(
            result16.lowercased() == "hello-world 123" && result16.count == "hello-world 123".count,
            "randomCase preserves letters and non-letters while randomizing case",
            details: "actual: \(result16)"
        )

        let watcher = RecordingsFolderWatcher()
        watcher.activeRecordingSessions = true
        watcher.clipboardMonitor.activeSessionClipboardContentWithStacking = "session-fallback"
        watcher.clipboardMonitor.recentClipboardContent = "global-fallback"
        watcher.clipboardMonitor.recentClipboardContentWithStacking = "<clipboard-context-1>\nglobal-stacking\n</clipboard-context-1>"
        recordingsWatcher = watcher

        let action17 = "{{clipboardContext}}"
        let meta17: [String: Any] = [
            "clipboardContext": "",
            runtimeClipboardContextLockedKey: true
        ]
        let result17 = processDynamicPlaceholders(action: action17, metaJson: meta17, actionType: .insert).text
        assertEqual(result17, "", "clipboardContext lock preserves explicit empty snapshot (no fallback)")

        let action18 = "{{clipboardContext}}"
        let meta18: [String: Any] = [
            "clipboardContext": "frozen-snapshot",
            runtimeClipboardContextLockedKey: true
        ]
        let result18 = processDynamicPlaceholders(action: action18, metaJson: meta18, actionType: .insert).text
        assertEqual(result18, "frozen-snapshot", "clipboardContext lock preserves frozen non-empty snapshot")

        let action19 = "{{clipboardContext}}"
        let meta19: [String: Any] = ["clipboardContext": ""]
        let result19 = processDynamicPlaceholders(action: action19, metaJson: meta19, actionType: .insert).text
        assertEqual(result19, "session-fallback", "unlocked clipboardContext falls back to active session content")

        watcher.activeRecordingSessions = false

        let action20 = "{{clipboardContext}}"
        let meta20: [String: Any] = ["clipboardContext": ""]
        let result20 = processDynamicPlaceholders(action: action20, metaJson: meta20, actionType: .insert).text
        assertEqual(result20, "global-fallback", "unlocked clipboardContext falls back to global clipboard content")

        let action21 = "{{clipboardContext}}"
        let meta21: [String: Any] = [
            "clipboardContext": "",
            "clipboardStacking": true
        ]
        let result21 = processDynamicPlaceholders(action: action21, metaJson: meta21, actionType: .insert).text
        assertEqual(result21, "<clipboard-context-1>\nglobal-stacking\n</clipboard-context-1>", "unlocked clipboardContext stacking fallback stays intact")

        stubSelectedText = "live-selection"
        stubAppContext = "live-app-context"
        stubAppVocabulary = "live-app-vocabulary"
        stubActiveURL = "https://live.example.com"

        let action22 = "{{selectedText}}|{{clipboardContext}}|{{frontApp}}|{{frontAppUrl}}|{{appContext}}|{{appVocabulary}}"
        let meta22: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            "selectedText": "live-selection",
            "clipboardContext": "live-clipboard",
            "frontApp": "Live App",
            "frontAppName": "Live App",
            "frontAppUrl": "https://live.example.com",
            "appContext": "live-app-context",
            "appVocabulary": "live-app-vocabulary"
        ]
        let result22 = processDynamicPlaceholders(action: action22, metaJson: meta22, actionType: .insert).text
        assertEqual(
            result22,
            "live-selection|live-clipboard|Live App|https://live.example.com|live-app-context|live-app-vocabulary",
            "copy-action live context flag uses provided live values for all context placeholders"
        )

        watcher.activeRecordingSessions = true
        watcher.clipboardMonitor.activeSessionSelectedText = "session-selected"
        watcher.clipboardMonitor.activeSessionClipboardContentWithStacking = "session-clipboard"
        watcher.clipboardMonitor.recentClipboardContent = "global-fallback"
        watcher.clipboardMonitor.recentClipboardContentWithStacking = "<clipboard-context-1>\nglobal-fallback\n</clipboard-context-1>"

        let action23 = "{{selectedText}}"
        let meta23: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            "selectedText": ""
        ]
        let result23 = processDynamicPlaceholders(action: action23, metaJson: meta23, actionType: .insert).text
        assertEqual(result23, "", "copy-action live context keeps empty selectedText without fallback")

        let action24 = "{{clipboardContext}}"
        let meta24: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            runtimeClipboardContextLockedKey: true,
            "clipboardContext": ""
        ]
        let result24 = processDynamicPlaceholders(action: action24, metaJson: meta24, actionType: .insert).text
        assertEqual(result24, "", "copy-action live context keeps empty clipboardContext without fallback")

        let action25 = "{{frontApp}}"
        let meta25: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            "frontApp": "",
            "frontAppName": ""
        ]
        let result25 = processDynamicPlaceholders(action: action25, metaJson: meta25, actionType: .insert).text
        assertEqual(result25, "", "copy-action live context keeps empty frontApp without fallback")

        let action26 = "{{frontAppUrl}}"
        let meta26: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            "frontAppUrl": ""
        ]
        let result26 = processDynamicPlaceholders(action: action26, metaJson: meta26, actionType: .insert).text
        assertEqual(result26, "", "copy-action live context keeps empty frontAppUrl without fallback")

        let action27 = "{{appContext}}"
        let meta27: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            "appContext": ""
        ]
        let result27 = processDynamicPlaceholders(action: action27, metaJson: meta27, actionType: .insert).text
        assertEqual(result27, "", "copy-action live context keeps empty appContext without fallback")

        let action28 = "{{appVocabulary}}"
        let meta28: [String: Any] = [
            runtimeCopyActionLiveContextKey: true,
            "appVocabulary": ""
        ]
        let result28 = processDynamicPlaceholders(action: action28, metaJson: meta28, actionType: .insert).text
        assertEqual(result28, "", "copy-action live context keeps empty appVocabulary without fallback")

        let action29 = "{{swResult::ensureSentence}}"
        let meta29: [String: Any] = ["llmResult": "in this case,"]
        let result29 = processDynamicPlaceholders(action: action29, metaJson: meta29, actionType: .insert).text
        assertEqual(result29, "In this case,", "ensureSentence preserves trailing comma")

        let action30 = "{{swResult::ensureSentence}}"
        let meta30: [String: Any] = ["llmResult": "in this case;"]
        let result30 = processDynamicPlaceholders(action: action30, metaJson: meta30, actionType: .insert).text
        assertEqual(result30, "In this case;", "ensureSentence preserves trailing semicolon")

        let action31 = "{{swResult::ensureSentence}}"
        let meta31: [String: Any] = ["llmResult": "in this case:"]
        let result31 = processDynamicPlaceholders(action: action31, metaJson: meta31, actionType: .insert).text
        assertEqual(result31, "In this case:", "ensureSentence preserves trailing colon")

        let action32 = "{{swResult::EnSuReSeNtEnCe}}"
        let meta32: [String: Any] = ["llmResult": "hello world"]
        let result32 = processDynamicPlaceholders(action: action32, metaJson: meta32, actionType: .insert).text
        assertEqual(result32, "Hello world.", "placeholder transform names are case-insensitive")

        let action33 = "{{swResult::ensureSentence}}"
        let meta33: [String: Any] = ["llmResult": "this is perhaps beyond the scope of this class, but…"]
        let result33 = processDynamicPlaceholders(action: action33, metaJson: meta33, actionType: .insert).text
        assertEqual(result33, "This is perhaps beyond the scope of this class, but…", "ensureSentence preserves trailing unicode ellipsis")

        let action34 = "{{swResult::ensureSentence}}"
        let meta34: [String: Any] = ["llmResult": "*one. two. three.*"]
        let result34 = processDynamicPlaceholders(action: action34, metaJson: meta34, actionType: .insert).text
        assertEqual(result34, "*One. two. three.*", "ensureSentence preserves punctuation inside trailing markdown emphasis")

        let action35 = "{{swResult::ensureSentence}}"
        let meta35: [String: Any] = ["llmResult": "(\"hello world.\")"]
        let result35 = processDynamicPlaceholders(action: action35, metaJson: meta35, actionType: .insert).text
        assertEqual(result35, "(\"Hello world.\")", "ensureSentence preserves punctuation inside trailing wrappers")

        let action36 = "{{swResult||\\b(api|sdk)\\b||${1::UpPeRcAsE}}}"
        let meta36: [String: Any] = ["llmResult": "api and sdk"]
        let result36 = processDynamicPlaceholders(action: action36, metaJson: meta36, actionType: .insert).text
        assertEqual(result36, "API and SDK", "capture transform names are case-insensitive")

        stubSelectedText = ""
        stubAppContext = ""
        stubAppVocabulary = ""
        stubActiveURL = nil
        recordingsWatcher = nil
    }
}

@main
struct PlaceholderRegexPipelineRegressionRunner {
    static func main() {
        runPlaceholderRegexPipelineRegressionTests()
    }
}
