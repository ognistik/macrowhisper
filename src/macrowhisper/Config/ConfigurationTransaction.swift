import Foundation

/// The revision a client read before preparing a configuration edit.
///
/// `generation` changes when a manager starts or selects another config path;
/// `version` changes after every accepted reload or write in that generation;
/// and `fingerprint` identifies the bytes and file identity currently on disk.
/// Keeping all three values makes a draft bound to one daemon/configuration
/// identity rather than only to a modification date.
struct ConfigurationRevision: Codable, Equatable, Hashable {
    let generation: String
    let version: UInt64
    let fingerprint: String

    init(generation: String, version: UInt64, fingerprint: String) {
        self.generation = generation
        self.version = version
        self.fingerprint = fingerprint
    }
}

/// A complete, accepted manager view returned to an editor client.
struct ConfigurationSnapshot: Codable {
    let config: AppConfiguration
    let revision: ConfigurationRevision
    let configPath: String
    let diskIsValid: Bool
    let isLegacyOnDisk: Bool
    /// Disk diagnostics are kept separate from the accepted runtime fallback.
    /// An invalid file can therefore be displayed as read-only without
    /// pretending that the in-memory defaults replaced it on disk.
    let diskIssues: [ConfigValidationIssue]

    init(
        config: AppConfiguration,
        revision: ConfigurationRevision,
        configPath: String,
        diskIsValid: Bool = true,
        isLegacyOnDisk: Bool = false,
        diskIssues: [ConfigValidationIssue] = []
    ) {
        self.config = config
        self.revision = revision
        self.configPath = configPath
        self.diskIsValid = diskIsValid
        self.isLegacyOnDisk = isLegacyOnDisk
        self.diskIssues = diskIssues
    }
}

/// JSON values used by the structured editor contract. Integer values remain
/// integers so fields such as `history` cannot accidentally accept a decimal
/// or a boolean through Foundation's NSNumber bridging.
enum ConfigurationJSONValue: Codable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([ConfigurationJSONValue])
    case object([String: ConfigurationJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "non-finite numbers are not valid configuration values"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ConfigurationJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ConfigurationJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "non-finite numbers are not valid configuration values"
                    )
                )
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

enum ConfigurationEditOperation: String, Codable {
    case set
    case remove
}

/// One leaf or action-map edit. Path components are kept as an array so an
/// action name can contain punctuation, dots, or spaces without being parsed as
/// additional fields.
struct ConfigurationEdit: Codable, Equatable {
    let path: [String]
    let operation: ConfigurationEditOperation
    let value: ConfigurationJSONValue?

    init(
        path: [String],
        operation: ConfigurationEditOperation,
        value: ConfigurationJSONValue? = nil
    ) {
        self.path = path
        self.operation = operation
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case path, operation, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode([String].self, forKey: .path)
        operation = try container.decode(ConfigurationEditOperation.self, forKey: .operation)
        // `decodeIfPresent` maps both an omitted value and an explicit JSON
        // null to nil. The editor needs those states to remain distinct: null
        // is a valid value for nullable fields, while an omitted set value is
        // malformed.
        if container.contains(.value) {
            value = try container.decode(ConfigurationJSONValue.self, forKey: .value)
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(operation, forKey: .operation)
        if let value {
            try container.encode(value, forKey: .value)
        }
    }
}

enum ConfigurationTransactionErrorCode: String, Codable {
    case malformedEdit
    case invalidPath
    case typeMismatch
    case outOfRange
    case validationFailed
    case staleRevision
    case invalidDiskState
    case legacyConfiguration
    case unknownKey
    case unsupportedVersion
    case persistenceFailed
    case encodingFailed
    case resourceMismatch
}

/// Stable, field-addressable failure returned by structured transactions.
struct ConfigurationTransactionError: Error, LocalizedError, Codable, Equatable {
    let code: ConfigurationTransactionErrorCode
    let path: [String]
    let message: String
    let issues: [ConfigValidationIssue]

    init(
        code: ConfigurationTransactionErrorCode,
        path: [String] = [],
        message: String,
        issues: [ConfigValidationIssue] = []
    ) {
        self.code = code
        self.path = path
        self.message = message
        self.issues = issues
    }

    var errorDescription: String? { message }
}

/// Structured API result. The throwing closure API below is convenient for
/// existing CLI callers, while editor/server code can return this value
/// without translating an error into a string first.
enum ConfigurationTransactionResult {
    case committed(ConfigurationSnapshot)
    case rejected(ConfigurationTransactionError)

    var snapshot: ConfigurationSnapshot? {
        guard case .committed(let snapshot) = self else { return nil }
        return snapshot
    }

    var error: ConfigurationTransactionError? {
        guard case .rejected(let error) = self else { return nil }
        return error
    }

    var isCommitted: Bool {
        if case .committed = self { return true }
        return false
    }
}
