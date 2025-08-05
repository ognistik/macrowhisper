import Foundation

/// Manages JSON schema discovery and configuration file schema reference
class SchemaManager {
    private static let schemaFileName = "macrowhisper-schema.json"
    private static let schemaUrl = "https://raw.githubusercontent.com/oristarium/macrowhisper-cli/main/macrowhisper-schema.json"
    
    /// Debug method to show what paths are being checked (temporary)
    static func debugSchemaPaths() {
        let binaryPath = getCurrentBinaryPath()
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        print("  Binary path: \(binaryPath)")
        print("  Binary directory: \(binaryDir)")
        
        let localSchemaPath = (binaryDir as NSString).appendingPathComponent(schemaFileName)
        print("  Checking for schema at: \(localSchemaPath)")
        print("  Schema file exists: \(FileManager.default.fileExists(atPath: localSchemaPath))")
        
        // Also check current directory (for testing scenarios)
        let currentDir = FileManager.default.currentDirectoryPath
        let currentDirSchemaPath = (currentDir as NSString).appendingPathComponent(schemaFileName)
        print("  Current directory: \(currentDir)")
        print("  Checking in current dir: \(currentDirSchemaPath)")
        print("  Schema in current dir exists: \(FileManager.default.fileExists(atPath: currentDirSchemaPath))")
    }
    
    /// Find the schema file path using similar logic to ServiceManager's binary path detection
    static func findSchemaPath() -> String? {
        let binaryPath = getCurrentBinaryPath()
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        logDebug("Binary path: \(binaryPath)")
        logDebug("Binary directory: \(binaryDir)")
        
        // Strategy 0: Check current directory first (for testing scenarios)
        let currentDir = FileManager.default.currentDirectoryPath
        let currentDirSchemaPath = (currentDir as NSString).appendingPathComponent(schemaFileName)
        if FileManager.default.fileExists(atPath: currentDirSchemaPath) {
            logDebug("Found schema file in current directory: \(currentDirSchemaPath)")
            return currentDirSchemaPath
        }
        
        // Strategy 1: Look for schema file in the same directory as the binary
        let localSchemaPath = (binaryDir as NSString).appendingPathComponent(schemaFileName)
        logDebug("Checking for schema file at: \(localSchemaPath)")
        if FileManager.default.fileExists(atPath: localSchemaPath) {
            logDebug("Found schema file alongside binary: \(localSchemaPath)")
            return localSchemaPath
        } else {
            logDebug("Schema file not found alongside binary at: \(localSchemaPath)")
        }
        
        // Strategy 2: For Homebrew installations, check relative paths
        // Homebrew typically installs to /opt/homebrew/bin/ or /usr/local/bin/
        if binaryPath.contains("/homebrew/") || binaryPath.contains("/usr/local/") {
            // Try ../share/macrowhisper/ (common Homebrew pattern)
            let homebrewSchemaPath = URL(fileURLWithPath: binaryDir)
                .appendingPathComponent("../share/macrowhisper")
                .appendingPathComponent(schemaFileName)
                .standardized
                .path
            
            if FileManager.default.fileExists(atPath: homebrewSchemaPath) {
                logDebug("Found schema file in Homebrew share directory: \(homebrewSchemaPath)")
                return homebrewSchemaPath
            }
        }
        
        // Strategy 3: Check if we're in a development environment
        // Look for schema in the source directory structure
        let devSchemaPath = URL(fileURLWithPath: binaryDir)
            .appendingPathComponent("../../../")
            .appendingPathComponent(schemaFileName)
            .standardized
            .path
        
        if FileManager.default.fileExists(atPath: devSchemaPath) {
            logDebug("Found schema file in development directory: \(devSchemaPath)")
            return devSchemaPath
        }
        
        logDebug("Schema file not found locally")
        return nil
    }
    
    /// Get the schema reference to add to configuration files
    /// Only returns local file paths - does not fall back to remote URLs for offline operation
    static func getSchemaReference() -> String? {
        if let localPath = findSchemaPath() {
            // Convert to file:// URL for local schema files
            return "file://\(localPath)"
        } else {
            // No fallback to remote - keep tool offline-capable
            return nil
        }
    }
    
    /// Check if a configuration file already has a schema reference
    static func hasSchemaReference(configPath: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logDebug("Could not read or parse config file at \(configPath)")
            return false
        }
        
        let hasSchema = jsonObject["$schema"] != nil
        logDebug("Config file contains $schema: \(hasSchema)")
        if hasSchema, let schemaRef = jsonObject["$schema"] as? String {
            logDebug("Schema reference found: \(schemaRef)")
        }
        return hasSchema
    }
    
    /// Get the current schema reference from a configuration file
    static func getCurrentSchemaReference(configPath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaRef = jsonObject["$schema"] as? String else {
            return nil
        }
        return schemaRef
    }
    
    /// Add schema reference to an existing configuration file
    static func addSchemaToConfig(configPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: configPath) else {
            logWarning("Configuration file does not exist: \(configPath)")
            return false
        }
        
        // Check if schema reference already exists
        if hasSchemaReference(configPath: configPath) {
            logDebug("Configuration file already has schema reference")
            return true
        }
        
        do {
            // Read the existing configuration
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("Failed to parse configuration as JSON object")
                return false
            }
            
            // Add schema reference (only if local schema file is available)
            guard let schemaReference = getSchemaReference() else {
                logError("Cannot add schema reference: local schema file not found")
                return false
            }
            
            json["$schema"] = schemaReference
            
            // Write back with pretty formatting
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            
            // Format the JSON to remove escaped slashes (same as ConfigurationManager)
            if let jsonString = String(data: updatedData, encoding: .utf8) {
                let formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                if let formattedData = formattedJson.data(using: .utf8) {
                    try formattedData.write(to: URL(fileURLWithPath: configPath))
                    logInfo("Added schema reference to configuration file")
                    return true
                }
            }
            
        } catch {
            logError("Failed to add schema reference to configuration: \(error.localizedDescription)")
        }
        
        return false
    }
    
    /// Remove schema reference from configuration file (for backward compatibility testing)
    static func removeSchemaFromConfig(configPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return false
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            
            // Remove schema reference
            json.removeValue(forKey: "$schema")
            
            // Write back with pretty formatting
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            
            if let jsonString = String(data: updatedData, encoding: .utf8) {
                let formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                if let formattedData = formattedJson.data(using: .utf8) {
                    try formattedData.write(to: URL(fileURLWithPath: configPath))
                    return true
                }
            }
            
        } catch {
            logError("Failed to remove schema reference: \(error.localizedDescription)")
        }
        
        return false
    }
    
    /// Get current binary path (reused from ServiceManager logic)
    private static func getCurrentBinaryPath() -> String {
        let originalPath = CommandLine.arguments[0]
        
        // If it's already an absolute path, clean it up and return
        if originalPath.hasPrefix("/") {
            return URL(fileURLWithPath: originalPath).standardized.path
        }
        
        // Try to find the binary in PATH
        if let pathFromWhich = findBinaryInPath(originalPath) {
            return pathFromWhich
        }
        
        // Resolve relative path against current directory
        let currentDir = FileManager.default.currentDirectoryPath
        let resolvedPath = URL(fileURLWithPath: currentDir)
            .appendingPathComponent(originalPath)
            .standardized
            .path
        
        return resolvedPath
    }
    
    /// Find binary in PATH environment variable (reused from ServiceManager)
    private static func findBinaryInPath(_ binaryName: String) -> String? {
        let executableName = URL(fileURLWithPath: binaryName).lastPathComponent
        
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        
        for pathDir in pathEnv.components(separatedBy: ":") {
            let candidatePath = URL(fileURLWithPath: pathDir)
                .appendingPathComponent(executableName)
                .standardized
                .path
            
            if FileManager.default.fileExists(atPath: candidatePath) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory),
                   !isDirectory.boolValue,
                   FileManager.default.isExecutableFile(atPath: candidatePath) {
                    return candidatePath
                }
            }
        }
        
        return nil
    }
}