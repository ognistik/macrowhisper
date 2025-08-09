//
//  Workflow+Environment.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

extension Workflow {
    static func envvar(_ key: String) -> String? {
        Env.environment[key]
    }

    enum Env {
        static let environment: [String:String] = ProcessInfo.processInfo.environment
        static let workflowUID: String? = environment["alfred_workflow_uid"]
        static let workflowName: String? = environment["alfred_workflow_name"]
        static let debugPaneIsOpen: Bool  =  environment["alfred_debug"] == "1"
        static let workflowVersion: String? = environment["alfred_workflow_version"]
        static let workflowBundleID: String? = environment["alfred_workflow_bundleid"]
        static let preferences: String? = environment["alfred_preferences"]
        static let workflowCacheDirectory: String? = environment["alfred_workflow_cache"]
        static let workflowDataDirectory: String? = environment["alfred_workflow_data"]
    }
}


