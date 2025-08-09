//
//  ScriptFilter+Item.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct Item: Codable, Inflatable {
    var uid: String?
    var title: String
    var match: String?
    var subtitle: String
    var autocomplete: String?
    var quicklookurl: String?
    var arg: Argument?
    var action: Argument?
    var variables: Argument?
    var valid: Bool
    var icon: Icon?
    var text: Text?
    var type: ItemType?
    var fn: Modifier?
    var cmd: Modifier?
    var alt: Modifier?
    var ctrl: Modifier?
    var shift: Modifier?
    var cmdalt: Modifier?
    var cmdshift: Modifier?
    var altshift: Modifier?
    var ctrlshift: Modifier?
    
    init(
        title: String,
        icon: Icon? = nil,
        text: Text? = nil,
        uid: String? = nil,
        valid: Bool = true,
        fn: Modifier? = nil,
        arg: Argument? = nil,
        match: String? = nil,
        cmd: Modifier? = nil,
        alt: Modifier? = nil,
        subtitle: String = "",
        ctrl: Modifier? = nil,
        shift: Modifier? = nil,
        cmdalt: Modifier? = nil,
        action: Argument? = nil,
        cmdshift: Modifier? = nil,
        altshift: Modifier? = nil,
        ctrlshift: Modifier? = nil,
        variables: Argument? = nil,
        type: Item.ItemType? = nil,
        quicklookurl: String? = nil,
        autocomplete: String? = nil
    ) {
        self.autocomplete = autocomplete
        self.quicklookurl = quicklookurl
        self.variables = variables
        self.subtitle = subtitle
        self.action = action
        self.title = title
        self.valid = valid
        self.match = match
        self.shift = shift
        self.icon = icon
        self.text = text
        self.type = type
        self.ctrl = ctrl
        self.uid = uid
        self.arg = arg
        self.cmd = cmd
        self.alt = alt
        self.fn = fn
        self.cmdalt = cmdalt
        self.cmdshift = cmdshift
        self.altshift = altshift
        self.ctrlshift = ctrlshift
    }
    
    init() { self.init(title: "") }
    var item: Item { self }
    
    enum ItemType: String, Codable {
        case file = "file"
        case fileSkipCheck = "file:skipcheck"
    }
}

struct Mods: Codable {
    let fn: Modifier?
    let cmd: Modifier?
    let alt: Modifier?
    let ctrl: Modifier?
    let shift: Modifier?
    let cmdalt: Modifier?
    let cmdshift: Modifier?
    let altshift: Modifier?
    let ctrlshift: Modifier?
    init(
        fn: Modifier? = nil,
        cmd: Modifier? = nil,
        alt: Modifier? = nil,
        ctrl: Modifier? = nil,
        shift: Modifier? = nil,
        cmdalt: Modifier? = nil,
        cmdshift: Modifier? = nil,
        altshift: Modifier? = nil,
        ctrlshift: Modifier? = nil
    ) {
        self.shift = shift
        self.ctrl = ctrl
        self.cmd = cmd
        self.alt = alt
        self.fn = fn
        self.cmdalt = cmdalt
        self.cmdshift = cmdshift
        self.altshift = altshift
        self.ctrlshift = ctrlshift
    }
}

struct Modifier: Codable, Equatable, Inflatable {
    var variables: Argument?
    var subtitle: String?
    var arg: Argument
    var icon: Icon?
    var valid: Bool

    init(
        arg: Argument = .string(""),
        subtitle: String? = nil,
        icon: Icon? = nil,
        variables: Argument? = nil,
        valid: Bool = true
    ) {
        self.variables = variables
        self.subtitle = subtitle
        self.valid = valid
        self.icon = icon
        self.arg = arg
    }
    
    init() {
        self.variables = nil
        self.subtitle = nil
        self.valid = true
        self.icon = nil
        self.arg = .string("")
    }

    @discardableResult
    mutating func suppressParentVariables() -> Bool {
        guard variables == nil else { return false }
        self.variables = .nested(["":.string("")])
        return true
    }
    
    static let suppressed: Modifier = .init(arg: .string(""), subtitle: "", valid: false)
}

extension Item {
    private enum CodingKeys: String, CodingKey {
        case uid, title, subtitle, arg, icon,
             valid, autocomplete, type, mods,
             quicklookurl, text, action, match,
             variables
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(title, forKey: .title)
        try container.encode(valid, forKey: .valid)
        try container.encodeIfPresent(uid, forKey: .uid)
        try container.encodeIfPresent(arg, forKey: .arg)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(match, forKey: .match)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(autocomplete, forKey: .autocomplete)
        try container.encodeIfPresent(quicklookurl, forKey: .quicklookurl)
        if let variables = variables {
            guard variables.hasValidVariablesStructure else {
                preconditionFailure("Variables must be passed on as [String:.string(String)]")
            }
            try container.encode(variables, forKey: .variables)
        }
        if ![cmd, alt, fn, ctrl, shift, cmdshift, cmdalt, altshift, ctrlshift].allSatisfy({ $0 == nil }) {
            let wrapper = Mods(fn: fn, cmd: cmd, alt: alt, ctrl: ctrl, shift: shift, cmdalt: cmdalt,
                               cmdshift: cmdshift, altshift: altshift, ctrlshift: ctrlshift)
            try container.encode(wrapper, forKey: .mods)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        valid = try container.decode(Bool.self, forKey: .valid)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decodeIfPresent(Text.self, forKey: .text)
        match = try container.decodeIfPresent(String.self, forKey: .match)
        type = try container.decodeIfPresent(ItemType.self, forKey: .type)
        uid = try container.decodeIfPresent(String.self, forKey: .uid)
        arg = try container.decodeIfPresent(Argument.self, forKey: .arg)
        icon = try container.decodeIfPresent(Icon.self, forKey: .icon)
        action = try container.decodeIfPresent(Argument.self, forKey: .action)
        variables = try container.decodeIfPresent(Argument.self, forKey: .variables)
        autocomplete = try container.decodeIfPresent(String.self, forKey: .autocomplete)
        quicklookurl = try container.decodeIfPresent(String.self, forKey: .quicklookurl)
        let wrapper: Mods? = try container.decodeIfPresent(Mods.self, forKey: .mods)
        fn = wrapper?.fn ?? nil
        cmd = wrapper?.cmd ?? nil
        alt = wrapper?.alt ?? nil
        ctrl = wrapper?.ctrl ?? nil
        shift = wrapper?.shift ?? nil
        cmdalt = wrapper?.cmdalt ?? nil
        cmdshift = wrapper?.cmdshift ?? nil
        altshift = wrapper?.altshift ?? nil
        ctrlshift = wrapper?.cmdshift ?? nil
    }
}

extension Mods {
    enum CodingKeys: String, CodingKey {
        case cmd, alt, fn, ctrl, shift
        case cmdshift = "cmd+shift"
        case cmdalt = "cmd+alt"
        case altshift = "alt+shift"
        case ctrlshift = "ctrl+shift"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(ctrlshift, forKey: .ctrlshift)
        try container.encodeIfPresent(cmdshift, forKey: .cmdshift)
        try container.encodeIfPresent(altshift, forKey: .altshift)
        try container.encodeIfPresent(cmdalt, forKey: .cmdalt)
        try container.encodeIfPresent(shift, forKey: .shift)
        try container.encodeIfPresent(ctrl, forKey: .ctrl)
        try container.encodeIfPresent(cmd, forKey: .cmd)
        try container.encodeIfPresent(alt, forKey: .alt)
        try container.encodeIfPresent(fn, forKey: .fn)
    }
}

extension Modifier {
    enum CodingKeys: String, CodingKey {
        case arg, subtitle, valid, variables, icon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(arg, forKey: .arg)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(valid, forKey: .valid)
        try container.encode(icon, forKey: .icon)
        if let variables = variables {
            guard variables.hasValidVariablesStructure else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Variables must be passed on as [String:String]"
                    )
                )
            }
            try container.encode(variables, forKey: .variables)
        }
    }
}

extension Item {
    mutating func addVariables(_ vars: [String:String]) {
        let new: [String:Argument] = vars.reduce(into: [:]) { partialResult, kv in
            partialResult[kv.key] = .string(kv.value)
        }
        if case var .nested(variables) = variables {
            variables.merge(new, uniquingKeysWith: { _, new in new })
            self.variables = .nested(variables)
        } else {
            self.variables = .nested(new)
        }
    }
    
    mutating func addVariable(key: String, _ value: String) {
        if case var .nested(variables) = variables {
            variables[key] = .string(value)
            self.variables = .nested(variables)
        } else {
            self.variables = .nested([key: .string(value)])
        }
    }
}


