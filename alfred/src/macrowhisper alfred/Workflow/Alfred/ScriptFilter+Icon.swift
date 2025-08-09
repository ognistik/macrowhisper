//
//  ScriptFilter+Icon.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct Icon: Codable, Equatable, ExpressibleByStringLiteral {
    enum IconType: String, Codable {
        case fileicon, filetype
    }
    var type: IconType?
    var path: String
    
    init(path: String, type: IconType? = nil) {
        self.path = path
        self.type = type
    }
    
    init(stringLiteral value: String) {
        self = Icon(path: value)
    }
}

extension Icon {
    static let info: Icon = "images/icons/info.png"
    static let failure: Icon = "images/icons/failure.png"
}


