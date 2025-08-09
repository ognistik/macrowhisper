//
//  MacrowhisperConfig.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct MacrowhisperConfig: Decodable {
    struct Defaults: Decodable {
        let actionDelay: Double?
        let activeAction: String?
        let autoUpdateConfig: Bool?
        let clipboardBuffer: Int?
        let history: Int?
        let icon: String?
        let pressReturn: Bool?
        let restoreClipboard: Bool?
    }

    struct Insert: Decodable { let action: String; let icon: String?; let triggerVoice: String? }
    struct ScriptAS: Decodable { let action: String; let triggerModes: String? }
    struct ScriptShell: Decodable { let action: String }
    struct Shortcut: Decodable { let action: String; let triggerVoice: String? }
    struct URLAction: Decodable { let action: String; let icon: String?; let openBackground: Bool?; let triggerVoice: String? }

    let defaults: Defaults?
    let inserts: [String: Insert]?
    let scriptsAS: [String: ScriptAS]?
    let scriptsShell: [String: ScriptShell]?
    let shortcuts: [String: Shortcut]?
    let urls: [String: URLAction]?
}

enum ActionKind: String, CaseIterable {
    case url = "URL"
    case shortcut = "Shortcut"
    case insert = "Insert"
    case applescript = "AppleScript"
    case shell = "Shell"
}

struct UnifiedAction {
    let name: String
    let kind: ActionKind
    let actionText: String
}

extension MacrowhisperConfig {
    func allActions() -> [UnifiedAction] {
        var results: [UnifiedAction] = []
        if let urls { for (name, v) in urls { results.append(.init(name: name, kind: .url, actionText: v.action)) } }
        if let shortcuts { for (name, v) in shortcuts { results.append(.init(name: name, kind: .shortcut, actionText: v.action)) } }
        if let inserts { for (name, v) in inserts { results.append(.init(name: name, kind: .insert, actionText: v.action)) } }
        if let scriptsAS { for (name, v) in scriptsAS { results.append(.init(name: name, kind: .applescript, actionText: v.action)) } }
        if let scriptsShell { for (name, v) in scriptsShell { results.append(.init(name: name, kind: .shell, actionText: v.action)) } }
        return results
    }
}


