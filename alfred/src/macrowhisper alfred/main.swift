//
//  main.swift
//  Macrowhisper Alfred
//
//  Created by Robert J. P. Oberg  on 8/7/25.
//

import Foundation

// MARK: - Alfred env inputs

enum EnvKeys {
    static let configPath = "configPath" // provided by Alfred Variable
    static let pressReturn = "pressReturn"
    static let pressCmd = "pressCmd"
    static let pressOpt = "pressOpt"
    static let pressCmdOpt = "pressCmdOpt"
    static let pressCtrl = "pressCtrl"
    static let dictateMode = "dictateMode"
    static let kmMacro = "kmMacro"
    static let debugKM = "debugKM"
}

enum OutputVarKeys {
    static let pressMods = "pressMods"
    static let theAction = "theAction"
}

private let typeFilterPrefix: String = "@"

// MARK: - CLI

struct CLI {
    static let queryFull: String = Workflow.userInput ?? ""
    static var query: String = queryFull

    static func run() -> Never {
        guard let configPath: String = Workflow.Env.environment[EnvKeys.configPath]?.trimmed, !configPath.isEmpty else {
            Workflow.quit("Missing 'configPath' variable from Alfred.")
        }

        // If selection variables are present, perform side-effect actions and exit
        if executeSelectionIfApplicable() {
            Workflow.exit(.success)
        }

        let fm: FileManager = .default
        guard let config: MacrowhisperConfig = ConfigLoader.loadConfig(from: configPath, fm: fm) else {
            Workflow.quit("Unable to read/parse config at path", configPath)
        }

        // Build actions
        let actions: [UnifiedAction] = config.allActions()

        // If user is in category selection mode ("@..." without a space), show filtered kinds list only
        if let typeListResponse = typeSelectionResponseIfApplicable(input: queryFull) {
            Workflow.return(typeListResponse)
        }

        // Determine filtering by type once a space is present (e.g., "@url <query>") or no '@' prefix
        let (typeFilter, searchTerm, categoryCompleted) = parseTypeFilter(input: queryFull)
        let filteredByType: [UnifiedAction] = {
            guard let typeFilter else { return actions }
            return actions.filter { $0.kind == typeFilter }
        }()

        let finalActions: [UnifiedAction] = {
            let term = searchTerm.trimmed
            // If category has just been completed (e.g., "@URL "), show full list (no fuzzy yet)
            if categoryCompleted { return filteredByType }
            guard !term.isEmpty else { return filteredByType }
            // Normalize term: treat spaces and case uniformly; strip diacritics in fuzzy
            let normTerm = term.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            // Match against the visible title text; when filtering by @Type, match only the name.
            let fuzzy = Fuzzy<UnifiedAction>(
                query: normTerm,
                getTargetText: {
                    if typeFilter != nil {
                        return $0.name
                    } else {
                        return "\($0.name) (\($0.kind.rawValue))"
                    }
                }
            )
            let orderedIndices = fuzzy.sorted(candidates: filteredByType, matchesOnly: true).map { $0.targetIndex }
            let ordered = orderedIndices.map { filteredByType[$0] }
            // Improve ranking: prioritize prefix matches (stable) while preserving fuzzy order within groups
            let lcTerm = normTerm.lowercased()
            var prefixFirst: [UnifiedAction] = []
            var others: [UnifiedAction] = []
            for a in ordered {
                let base = (typeFilter != nil) ? a.name : "\(a.name) (\(a.kind.rawValue))"
                let titleNorm = base
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    .lowercased()
                if titleNorm.hasPrefix(lcTerm) { prefixFirst.append(a) } else { others.append(a) }
            }
            return prefixFirst + others
        }()

        // Build items
        let searchTermLocal = searchTerm // capture for match logic
        let items: [Item] = finalActions.map { action in
            let fullTitle = "\(action.name) (\(action.kind.rawValue))"
            let displayedTitle = (typeFilter != nil) ? action.name : fullTitle
            var item = Item(title: displayedTitle)
            // Stable UID so Alfred can learn usage per action+type
            item.uid = "\(action.kind.rawValue)::\(action.name)"
            let subtitle = buildSubtitle()
            item.subtitle = subtitle
            item.valid = true
            item.text = Text(copy: action.actionText, largetype: action.actionText)
            item.quicklookurl = configPath
            // Enable TAB autocomplete on items:
            // - With @Type filter: "@Type Name"
            // - Without @Type filter: "Name (Type)"
            if let typeFilter {
                item.autocomplete = "@\(typeFilter.rawValue) \(action.name)"
            } else {
                item.autocomplete = fullTitle
            }
            // Alfred matching behavior:
            // - When a category is completed and no search term yet ("@Type "), provide a match containing "@Type " so items are visible.
            // - Once a search term exists (e.g., "@Type pr"), do NOT set match; let Alfred use title for ranking to avoid skew.
            if let typeFilter {
                if searchTermLocal.trimmed.isEmpty {
                    item.match = "@\(typeFilter.rawValue) \(action.name)"
                } else {
                    item.match = nil
                }
            } else {
                item.match = nil
            }
            // Pass variables via mods only; disable other mods
            // noMods (return)
            item.cmd = .suppressed
            item.alt = .suppressed
            // ctrl will be explicitly enabled below
            item.shift = .suppressed
            item.fn = .suppressed
            item.cmdshift = .suppressed
            item.cmdalt = .suppressed
            item.altshift = .suppressed
            item.ctrlshift = .suppressed

            // Parent item selection (no modifiers)
            item.arg = .string("")
            item.variables = .nested([
                OutputVarKeys.pressMods: .string("noMods"),
                OutputVarKeys.theAction: .string(action.name)
            ])

            // Explicit mod overrides
            item.cmd = .with({
                $0.valid = true
                $0.arg = .string("")
                $0.subtitle = "⌘ \(Workflow.Env.environment[EnvKeys.pressCmd] ?? "")"
                $0.variables = .nested([
                    OutputVarKeys.pressMods: .string("cmd"),
                    OutputVarKeys.theAction: .string(action.name)
                ])
            })
            item.alt = .with({
                $0.valid = true
                $0.arg = .string("")
                $0.subtitle = "⌥ \(Workflow.Env.environment[EnvKeys.pressOpt] ?? "")"
                $0.variables = .nested([
                    OutputVarKeys.pressMods: .string("opt"),
                    OutputVarKeys.theAction: .string(action.name)
                ])
            })
            item.cmdalt = .with({
                $0.valid = true
                $0.arg = .string("")
                $0.subtitle = "⌘⌥ \(Workflow.Env.environment[EnvKeys.pressCmdOpt] ?? "")"
                $0.variables = .nested([
                    OutputVarKeys.pressMods: .string("cmdOpt"),
                    OutputVarKeys.theAction: .string(action.name)
                ])
            })
            item.ctrl = .with({
                $0.valid = true
                $0.arg = .string("")
                $0.subtitle = "⌃ \(Workflow.Env.environment[EnvKeys.pressCtrl] ?? "")"
                $0.variables = .nested([
                    OutputVarKeys.pressMods: .string("ctrl"),
                    OutputVarKeys.theAction: .string(action.name)
                ])
            })
            return item
        }

        guard !items.isEmpty else {
            Workflow.return(.init(items: []))
        }
        Workflow.return(.init(items: items))
    }

    private static func buildSubtitle() -> String {
        let pressReturn = Workflow.Env.environment[EnvKeys.pressReturn] ?? ""
        let pressCmd = Workflow.Env.environment[EnvKeys.pressCmd] ?? ""
        let pressOpt = Workflow.Env.environment[EnvKeys.pressOpt] ?? ""
        let pressCmdOpt = Workflow.Env.environment[EnvKeys.pressCmdOpt] ?? ""
        let pressCtrl = Workflow.Env.environment[EnvKeys.pressCtrl] ?? ""
        return "⏎ \(pressReturn) • ⌘ \(pressCmd) • ⌥ \(pressOpt) • ⌘⌥ \(pressCmdOpt) • ⌃ \(pressCtrl)"
    }

    private static func parseTypeFilter(input: String) -> (ActionKind?, String, Bool) {
        // Return tuple: (kind?, restTerm, categoryCompleted)
        // categoryCompleted == true ONLY when input ends with a space after a resolvable category
        // and there is no further search term yet (e.g., "@URL ")
        let trimmedLeading = input
        guard trimmedLeading.hasPrefix(typeFilterPrefix) else { return (nil, trimmedLeading.trimmed, false) }
        let afterAtFull = String(trimmedLeading.dropFirst())
        // Support both "@url" and "@ url"; detect if a space exists and if it denotes completion boundary
        let hasSpace = afterAtFull.contains(" ")
        let (typeCandidateRaw, restRaw): (String, String) = {
            if let spaceIndex = afterAtFull.firstIndex(of: " ") {
                let typePart = String(afterAtFull[..<spaceIndex])
                let rest = String(afterAtFull[afterAtFull.index(after: spaceIndex)...])
                return (typePart, rest)
            } else {
                return (afterAtFull, "")
            }
        }()
        let typeCandidate = typeCandidateRaw.trimmingCharacters(in: .whitespaces)
        let kinds = ActionKind.allCases
        guard !typeCandidate.isEmpty else { return (nil, restRaw.trimmed, false) }

        // Fuzzy match against ActionKind names
        let fuzzy = Fuzzy<ActionKind>(query: typeCandidate, getTargetText: { $0.rawValue })
        let matches = fuzzy.sorted(candidates: kinds, matchesOnly: true)
        guard let match = matches.first else { return (nil, restRaw.trimmed, false) }
        let selectedKind = kinds[match.targetIndex]
        let restTrimmed = restRaw.trimmed
        let categoryCompleted = hasSpace && restTrimmed.isEmpty
        return (selectedKind, restTrimmed, categoryCompleted)
    }

    private static func typeSelectionResponseIfApplicable(input: String) -> Response? {
        // Do NOT trim the trailing space; it indicates category selection completion
        guard input.hasPrefix(typeFilterPrefix) else { return nil }
        let afterAt = String(input.dropFirst())
        let hasSpace = afterAt.contains(" ")
        if hasSpace { return nil } // once a space is present, we proceed to action listing

        let seed = afterAt.trimmingCharacters(in: .whitespaces)
        let kinds = ActionKind.allCases
        let kindItems: [Item] = {
            if seed.isEmpty {
                return kinds.map { kind in
                    var it = Item(title: kind.rawValue)
                    it.subtitle = "Filter actions by type"
                    it.autocomplete = "@\(kind.rawValue) "
                    it.valid = false
                    return it
                }
            } else {
                let fuzzy = Fuzzy<ActionKind>(query: seed, getTargetText: { $0.rawValue })
                let matches = fuzzy.sorted(candidates: kinds, matchesOnly: true)
                return matches.map { match in
                    let kind = kinds[match.targetIndex]
                    var it = Item(title: kind.rawValue)
                    it.subtitle = "Filter actions by type"
                    it.autocomplete = "@\(kind.rawValue) "
                    it.valid = false
                    return it
                }
            }
        }()
        return Response(items: kindItems)
    }
}

// MARK: - Selection Execution

private enum SelectionLabel: String {
    case scheduleAndDictate = "Schedule & Dictate"
    case scheduleOnly = "Schedule Only"
    case setAsActive = "Set as Active"
    case setAsActiveAndDictate = "Set as Active & Dictate"
    case executeAction = "Execute Action"
}

private func executeSelectionIfApplicable() -> Bool {
    let env = Workflow.Env.environment
    guard let pressMods = env[OutputVarKeys.pressMods], let actionName = env[OutputVarKeys.theAction] else {
        return false
    }

    // Resolve label based on pressed modifier
    let label: String? = {
        switch pressMods {
        case "noMods": return env[EnvKeys.pressReturn]
        case "cmd": return env[EnvKeys.pressCmd]
        case "opt": return env[EnvKeys.pressOpt]
        case "cmdOpt": return env[EnvKeys.pressCmdOpt]
        case "ctrl": return env[EnvKeys.pressCtrl]
        default: return nil
        }
    }()?.trimmed

    guard let label, !label.isEmpty else { return false }

    let dictateMode = env[EnvKeys.dictateMode] ?? ""
    let kmRaw = (env[EnvKeys.kmMacro] ?? "").lowercased()
    let kmMacroEnabled: Bool = ["true","1","yes","y"].contains(kmRaw)
    let debugKM: Bool = ["true","1","yes","y"].contains((env[EnvKeys.debugKM] ?? "").lowercased())
    let macrowhisperPath: String = ProcessRunner.which("macrowhisper") ?? "macrowhisper"
    let modeKey = dictateMode.trimmed

    func openURL(_ url: String) {
        let status = ProcessRunner.run(executable: "/usr/bin/open", arguments: ["-g", url])
        if debugKM { Workflow.log("open status(\(url)): \(status)") }
    }
    func runOSA(_ script: String) {
        let status = ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
        if debugKM { Workflow.log("osascript status: \(status)") }
    }

    // Execute sequences based on label
    switch SelectionLabel(rawValue: label) {
    case .scheduleAndDictate:
        openURL("superwhisper://record")
        if !modeKey.isEmpty { openURL("superwhisper://mode?key=\(modeKey)") }
        let status = ProcessRunner.run(executable: macrowhisperPath, arguments: ["--schedule-action", actionName])
        if debugKM { Workflow.log("macrowhisper --schedule-action status: \(status) @ \(macrowhisperPath)") }
    case .scheduleOnly:
        let status = ProcessRunner.run(executable: macrowhisperPath, arguments: ["--schedule-action", actionName])
        if debugKM { Workflow.log("macrowhisper --schedule-action status: \(status) @ \(macrowhisperPath)") }
        if !modeKey.isEmpty { openURL("superwhisper://mode?key=\(modeKey)") }
    case .setAsActive:
        let status = ProcessRunner.run(executable: macrowhisperPath, arguments: ["--action", actionName])
        if debugKM { Workflow.log("macrowhisper --action status: \(status) @ \(macrowhisperPath)") }
        if !modeKey.isEmpty { openURL("superwhisper://mode?key=\(modeKey)") }
        if kmMacroEnabled { runOSA("tell application \"Keyboard Maestro Engine\" to do script \"MW MBar\"") }
    case .setAsActiveAndDictate:
        let status = ProcessRunner.run(executable: macrowhisperPath, arguments: ["--action", actionName])
        if debugKM { Workflow.log("macrowhisper --action status: \(status) @ \(macrowhisperPath)") }
        openURL("superwhisper://record")
        if !modeKey.isEmpty { openURL("superwhisper://mode?key=\(modeKey)") }
        if kmMacroEnabled { runOSA("tell application \"Keyboard Maestro Engine\" to do script \"MW MBar\"") }
    case .executeAction:
        let status = ProcessRunner.run(executable: macrowhisperPath, arguments: ["--exec-action", actionName])
        if debugKM { Workflow.log("macrowhisper --exec-action status: \(status) @ \(macrowhisperPath)") }
    case .none:
        return false
    }

    // Show a small confirmation so the workflow has feedback
    Workflow.info("Action processed", "\(label) · \(actionName)")
}

CLI.run()

