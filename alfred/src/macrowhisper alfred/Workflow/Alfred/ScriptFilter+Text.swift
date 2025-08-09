//
//  ScriptFilter+Text.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct Text: Codable, Equatable {
    var copy: String?
    var largetype: String?

    init(copy: String? = nil, largetype: String? = nil) {
        self.copy = copy
        self.largetype = largetype
    }
}


