//
//  String+Extensions.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

extension StringProtocol {
    var trimmed: String { self.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension String {
    var expandingTildeInPathIfNeeded: String {
        (self as NSString).expandingTildeInPath
    }
}


