//
//  Workflow.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct Workflow {
    static let userInput: String? = {
        let arguments: [String] = CommandLine.arguments
        if arguments.indices.contains(1) {
            // Do NOT trim; trailing space is significant for category completion (e.g., "@URL ")
            let input: String = arguments[1].precomposedStringWithCanonicalMapping
            return input.isEmpty ? nil : input
        }
        return nil
    }()
    
    private static let stdOut: FileHandle = .standardOutput
    private static let stdErr: FileHandle = .standardError
}

extension Workflow {
    enum AnnotationLog: String {
        case warning = "[WARNING] "
        case error   = "[ERROR] "
        case info    = "[INFO] "
        case debug   = "[DEBUG] "
        case none    = ""
    }
    static func log(_ message: String, _ annotation: AnnotationLog = .none) {
        try? stdErr.write(contentsOf: Data("\(annotation.rawValue)\(message)\n".utf8))
    }
}

extension Workflow {
    enum ExitCode { case success, failure }
    static func exit(_ code: ExitCode) -> Never {
        switch code {
        case .success: Darwin.exit(EXIT_SUCCESS)
        case .failure: Darwin.exit(EXIT_FAILURE)
        }
    }
}

extension Workflow {
    static func `return`(_ response: Response, nullMessage: String = "No results...") -> Never {
        do {
            let response: Response = response
            guard !response.items.isEmpty else {
                let nullResponse: Response = .init(items: [.with({
                    $0.title = nullMessage
                    $0.icon = .info
                    $0.valid = false
                })], variables: response.variables)
                
                let json: String = try nullResponse.encoded()
                try stdOut.write(contentsOf: Data(json.utf8))
                exit(.success)
            }
            let json: String = try response.encoded()
            try stdOut.write(contentsOf: Data(json.utf8))
            exit(.success)
            
        } catch let error {
            quit("Error @ \(#function)", error.localizedDescription)
        }
    }
    
    static func quit(
        _ title: String,
        _ subtitle: String = "",
        icon: Icon = .failure,
        _ code: ExitCode = .failure
    ) -> Never {
        let text: String = "\(title). \(subtitle)"
        let output: String = try! Response(items: [.with {
            $0.title = title
            $0.subtitle = subtitle
            $0.arg = .string(title)
            $0.text = Text(copy: text, largetype: text)
            $0.icon = icon
        }]).encoded()
        try! stdOut.write(contentsOf: Data(output.utf8))
        exit(code)
    }
    
    static func info(_ title: String, _ subtitle: String = "") -> Never {
        quit(title, subtitle, icon: .info, .success)
    }
}


