//
//  ScriptFilter+Argument.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

enum Argument: Codable, Equatable {
    case string(String)
    case array([String])
    case nested([String:Argument])
}

extension Argument {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let strn): try container.encode(strn)
        case .nested(let nest): try container.encode(nest)
        case .array(let array): try container.encode(array)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let simple = try? container.decode(String.self)
        let array  = try? container.decode([String].self)
        let nested = try? container.decode([String:Argument].self)
        
        switch (simple, array, nested) {
        case let (.some(value),_,_): self = .string(value)
        case let (_,.some(value),_): self = .array(value)
        case let (_,_,.some(value)): self = .nested(value)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unable to decode Argument"
                )
            )
        }
    }
}

extension Argument {
    @inline(__always)
    var hasValidVariablesStructure: Bool {
        guard case .nested(let nest) = self, nest.values.allSatisfy({ $0.isString }) else {
            return false
        }
        return true
    }
    
    @inline(__always)
    private var isString: Bool {
        if case .string = self { return true } ; return false
    }
}


