//
//  ConfigLoader.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

enum ConfigLoader {
    static func loadConfig(from path: String, fm: FileManager = .default) -> MacrowhisperConfig? {
        let expanded = path.expandingTildeInPathIfNeeded
        guard fm.fileExists(atPath: expanded) else { return nil }
        guard let data: Data = fm.contents(atPath: expanded) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(MacrowhisperConfig.self, from: data)
    }
}


