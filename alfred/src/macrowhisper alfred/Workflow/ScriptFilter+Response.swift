//
//  ScriptFilter+Response.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct Response: Codable {
    var items: [Item]
    var rerun: Double?
    var variables: [String:String]?
    var skipknowledge: Bool?

    init(
        items: [Item] = [],
        rerun: Double? = nil,
        skipknowledge: Bool? = nil,
        variables: [String:String]? = nil
    ) {
        self.items = items
        self.rerun = rerun
        self.variables = variables
        self.skipknowledge = skipknowledge
    }
}

extension Response {
    enum CodingKeys: CodingKey {
        case items, rerun, variables, skipknowledge
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        if let runs = rerun { try container.encode(runs, forKey: .rerun) }
        if let variables = variables { try container.encode(variables, forKey: .variables) }
        if let skipknowledge = skipknowledge { try container.encode(skipknowledge, forKey: .skipknowledge) }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variables = try container.decodeIfPresent([String:String].self, forKey: .variables)
        skipknowledge = try container.decodeIfPresent(Bool.self, forKey: .skipknowledge)
        rerun = try container.decodeIfPresent(Double.self, forKey: .rerun)
        items = try container.decode([Item].self, forKey: .items)
    }
}

extension Response {
    subscript(_ index: Int) -> Item {
        get { items[index] }
        set { items[index] = newValue }
    }
    
    func encoded(
        sortKeys: Bool = false,
        encoder: JSONEncoder = .init()
    ) throws -> String {
        encoder.outputFormatting = [.prettyPrinted]
        if sortKeys {
            encoder.outputFormatting.update(with: .sortedKeys)
        }
        let json: Data = try encoder.encode(self)
        return String(data: json, encoding: .utf8)!
    }
    
    mutating func append(item: Item) { items.append(item) }
    mutating func append(contentsOf items: [Item]) {
        self.items.append(contentsOf: items.map { $0.item })
    }
}


