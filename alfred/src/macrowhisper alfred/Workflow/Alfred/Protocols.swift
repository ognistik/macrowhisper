//
//  Protocols.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

protocol Inflatable {
    init()
}

extension Inflatable {
    static func with(_ populator: (inout Self) throws -> ()) rethrows -> Self {
        var response = Self()
        try populator(&response)
        return response
    }
}


