import Foundation
import Cocoa

/// Configuration constants for clipboard monitoring bounds to prevent memory issues
private let MAX_SESSION_CLIPBOARD_CHANGES = 50  // Maximum clipboard changes per session
private let MAX_GLOBAL_CLIPBOARD_HISTORY = 100  // Maximum global history entries

/// Native clipboard attachment retention bounds. These are intentionally hard
/// limits: pasteboard providers are allowed to advertise arbitrarily large
/// image representations and the monitor must never retain those bytes without
/// a bound.
let CLIPBOARD_MAX_IMAGE_BYTES = 64 * 1024 * 1024
let CLIPBOARD_MAX_RETAINED_IMAGE_BYTES = 192 * 1024 * 1024

struct ClipboardAttachmentLimits: Equatable {
    let perImageBytes: Int
    let aggregateImageBytes: Int

    static let `default` = ClipboardAttachmentLimits(
        perImageBytes: CLIPBOARD_MAX_IMAGE_BYTES,
        aggregateImageBytes: CLIPBOARD_MAX_RETAINED_IMAGE_BYTES
    )

    init(
        perImageBytes: Int = CLIPBOARD_MAX_IMAGE_BYTES,
        aggregateImageBytes: Int = CLIPBOARD_MAX_RETAINED_IMAGE_BYTES
    ) {
        self.perImageBytes = max(0, perImageBytes)
        self.aggregateImageBytes = max(0, aggregateImageBytes)
    }
}

enum ClipboardImageFormat: String, Equatable, Hashable {
    case png
    case tiff
}

enum ClipboardAttachmentDropReason: String, Equatable, Hashable {
    case perImageLimit = "per-image-limit"
    case aggregateLimit = "aggregate-limit"
    case missingData = "missing-data"
    case invalidFileURL = "invalid-file-url"
    case featureDisabled = "feature-disabled"
}

/// An ordered semantic clipboard item. Text is deliberately a separate case
/// from attachments. In particular, an image/file item that also advertises an
/// incidental string representation is not silently downgraded to text.
enum ClipboardPayloadItem: Equatable, Hashable {
    case text(String)
    case fileURL(URL)
    case imagePNG(Data)
    case imageTIFF(Data)
    case unavailableImage(format: ClipboardImageFormat, byteCount: Int, reason: ClipboardAttachmentDropReason)
    case unavailableFileURL

    var isAttachment: Bool {
        switch self {
        case .text:
            return false
        case .fileURL, .imagePNG, .imageTIFF, .unavailableImage, .unavailableFileURL:
            return true
        }
    }

    var imageByteCount: Int {
        switch self {
        case .imagePNG(let data), .imageTIFF(let data):
            return data.count
        case .unavailableImage(_, let byteCount, _):
            return max(0, byteCount)
        case .text, .fileURL, .unavailableFileURL:
            return 0
        }
    }

    var retainedImageByteCount: Int {
        switch self {
        case .imagePNG(let data), .imageTIFF(let data):
            return data.count
        case .text, .fileURL, .unavailableImage, .unavailableFileURL:
            return 0
        }
    }

    var imageFormat: ClipboardImageFormat? {
        switch self {
        case .imagePNG, .unavailableImage(.png, _, _):
            return .png
        case .imageTIFF, .unavailableImage(.tiff, _, _):
            return .tiff
        case .text, .fileURL, .unavailableFileURL:
            return nil
        }
    }
}

typealias ClipboardOperationItem = ClipboardPayloadItem

enum ClipboardPayloadKind: String, Equatable, Hashable {
    case empty
    case text
    case attachments
}

/// The semantic payload used for history, filtering, transient detection, and
/// optional attachment handoff. `legacyText` is retained separately so turning
/// the feature off preserves the monitor's previous string projection.
struct ClipboardPayload: Equatable, Hashable {
    let items: [ClipboardPayloadItem]
    let legacyText: String?

    init(items: [ClipboardPayloadItem], legacyText: String? = nil) {
        self.items = items
        self.legacyText = legacyText
    }

    var kind: ClipboardPayloadKind {
        if items.contains(where: \.isAttachment) {
            return .attachments
        }
        if !items.isEmpty || legacyText != nil {
            return .text
        }
        return .empty
    }

    var isAttachmentClassified: Bool { kind == .attachments }
    var hasAttachments: Bool { isAttachmentClassified }

    var attachmentItems: [ClipboardPayloadItem] {
        items.filter(\.isAttachment)
    }

    var textItems: [String] {
        items.compactMap { item in
            if case .text(let value) = item { return value }
            return nil
        }
    }

    /// Text explicitly represented as a text item. Incidental string data on
    /// an image/file item is intentionally absent from this projection.
    var semanticText: String? {
        let values = textItems
        guard !values.isEmpty else { return nil }
        return values.joined(separator: "\n")
    }

    func textProjection(attachmentsEnabled: Bool) -> String? {
        if attachmentsEnabled {
            return semanticText
        }
        return legacyText ?? semanticText
    }

    var retainedImageByteCount: Int {
        items.reduce(into: 0) { total, item in
            total += item.retainedImageByteCount
        }
    }

    var unavailableAttachmentCount: Int {
        items.reduce(into: 0) { count, item in
            switch item {
            case .unavailableImage, .unavailableFileURL:
                count += 1
            case .text, .fileURL, .imagePNG, .imageTIFF:
                break
            }
        }
    }

    /// A process-local, representation-aware token. It permits correlation in
    /// diagnostics without exposing text, filenames, or image bytes.
    var fingerprint: String {
        var hasher = Hasher()
        hasher.combine(kind.rawValue)
        hasher.combine(legacyText != nil)
        for item in items {
            switch item {
            case .text(let value):
                hasher.combine("text")
                hasher.combine(value)
            case .fileURL(let url):
                hasher.combine("file-url")
                hasher.combine(url.absoluteString)
            case .imagePNG(let data):
                hasher.combine("png")
                hasher.combine(data.count)
                hasher.combine(data)
            case .imageTIFF(let data):
                hasher.combine("tiff")
                hasher.combine(data.count)
                hasher.combine(data)
            case .unavailableImage(let format, let byteCount, let reason):
                hasher.combine("unavailable-image")
                hasher.combine(format.rawValue)
                hasher.combine(byteCount)
                hasher.combine(reason.rawValue)
            case .unavailableFileURL:
                hasher.combine("unavailable-file-url")
            }
        }
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }

    /// Drops retained image bytes while preserving attachment classification.
    /// This is used by the aggregate history budget; an evicted image must not
    /// become text merely because its bytes were released.
    func droppingRetainedImages(reason: ClipboardAttachmentDropReason = .aggregateLimit) -> ClipboardPayload {
        let boundedItems = items.map { item -> ClipboardPayloadItem in
            switch item {
            case .imagePNG(let data):
                return .unavailableImage(format: .png, byteCount: data.count, reason: reason)
            case .imageTIFF(let data):
                return .unavailableImage(format: .tiff, byteCount: data.count, reason: reason)
            case .text, .fileURL, .unavailableImage, .unavailableFileURL:
                return item
            }
        }
        return ClipboardPayload(items: boundedItems, legacyText: legacyText)
    }
}

/// Supported representations retained for faithful restoration of the
/// original clipboard. This is intentionally distinct from `ClipboardPayload`:
/// restoration preserves all supported representations on each pasteboard item,
/// while context/handoff uses semantic items.
enum ClipboardOriginalRepresentation: Equatable, Hashable {
    case text(String)
    case fileURL(URL)
    case png(Data)
    case tiff(Data)
}

struct ClipboardOriginalItem: Equatable, Hashable {
    let representations: [ClipboardOriginalRepresentation]

    init(representations: [ClipboardOriginalRepresentation]) {
        self.representations = representations
    }
}

struct ClipboardOriginalSnapshot: Equatable, Hashable {
    let items: [ClipboardOriginalItem]
    let legacyText: String?
    let changeCount: Int?
    let omittedAttachmentCount: Int

    init(
        items: [ClipboardOriginalItem],
        legacyText: String? = nil,
        changeCount: Int? = nil,
        omittedAttachmentCount: Int = 0
    ) {
        self.items = items
        self.legacyText = legacyText
        self.changeCount = changeCount
        self.omittedAttachmentCount = max(0, omittedAttachmentCount)
    }

    var isComplete: Bool { omittedAttachmentCount == 0 }
    var isEmpty: Bool { isComplete && items.isEmpty && legacyText == nil }
    var retainedImageByteCount: Int {
        items.reduce(into: 0) { total, item in
            for representation in item.representations {
                switch representation {
                case .png(let data), .tiff(let data):
                    total += data.count
                case .text, .fileURL:
                    break
                }
            }
        }
    }
}

struct ClipboardPasteboardItemRepresentations: Equatable {
    let text: String?
    let fileURL: URL?
    let pngData: Data?
    let tiffData: Data?
    let hasFileURLRepresentation: Bool
    let hasPNGRepresentation: Bool
    let hasTIFFRepresentation: Bool

    init(
        text: String? = nil,
        fileURL: URL? = nil,
        pngData: Data? = nil,
        tiffData: Data? = nil,
        hasFileURLRepresentation: Bool? = nil,
        hasPNGRepresentation: Bool? = nil,
        hasTIFFRepresentation: Bool? = nil
    ) {
        self.text = text
        self.fileURL = fileURL
        self.pngData = pngData
        self.tiffData = tiffData
        self.hasFileURLRepresentation = hasFileURLRepresentation ?? (fileURL != nil)
        self.hasPNGRepresentation = hasPNGRepresentation ?? (pngData != nil)
        self.hasTIFFRepresentation = hasTIFFRepresentation ?? (tiffData != nil)
    }
}

private func makeBoundedClipboardPayload(
    items: [ClipboardPasteboardItemRepresentations],
    legacyText: String?,
    limits: ClipboardAttachmentLimits
) -> ClipboardPayload {
    var semanticItems: [ClipboardPayloadItem] = []
    var retainedImageBytes = 0

    for item in items {
        // An item is classified by its strongest supported representation. A
        // file URL wins over image/text; PNG wins over TIFF; text is considered
        // only when no attachment representation exists.
        if item.hasFileURLRepresentation {
            if let fileURL = item.fileURL, fileURL.isFileURL {
                semanticItems.append(.fileURL(fileURL))
            } else {
                semanticItems.append(.unavailableFileURL)
            }
            continue
        }

        if item.hasPNGRepresentation, let data = item.pngData {
            if data.count > limits.perImageBytes {
                semanticItems.append(.unavailableImage(
                    format: .png,
                    byteCount: data.count,
                    reason: .perImageLimit
                ))
            } else if retainedImageBytes + data.count > limits.aggregateImageBytes {
                semanticItems.append(.unavailableImage(
                    format: .png,
                    byteCount: data.count,
                    reason: .aggregateLimit
                ))
            } else {
                semanticItems.append(.imagePNG(data))
                retainedImageBytes += data.count
            }
            continue
        }

        // Some lazy providers advertise PNG but fail to vend its bytes while
        // still providing TIFF. Use TIFF in that case instead of declaring the
        // whole image unavailable.
        if item.hasPNGRepresentation, !item.hasTIFFRepresentation {
            semanticItems.append(.unavailableImage(format: .png, byteCount: 0, reason: .missingData))
            continue
        }

        if item.hasTIFFRepresentation {
            if let data = item.tiffData {
                if data.count > limits.perImageBytes {
                    semanticItems.append(.unavailableImage(
                        format: .tiff,
                        byteCount: data.count,
                        reason: .perImageLimit
                    ))
                } else if retainedImageBytes + data.count > limits.aggregateImageBytes {
                    semanticItems.append(.unavailableImage(
                        format: .tiff,
                        byteCount: data.count,
                        reason: .aggregateLimit
                    ))
                } else {
                    semanticItems.append(.imageTIFF(data))
                    retainedImageBytes += data.count
                }
            } else {
                semanticItems.append(.unavailableImage(format: .tiff, byteCount: 0, reason: .missingData))
            }
            continue
        }

        if let text = item.text {
            semanticItems.append(.text(text))
        }
    }

    // Preserve a pasteboard-level string when a provider exposes it outside
    // its item list. It is a legacy fallback only; attachment-classified items
    // above intentionally do not use this value as incidental context text.
    if semanticItems.isEmpty, let legacyText {
        semanticItems.append(.text(legacyText))
    }
    return ClipboardPayload(items: semanticItems, legacyText: legacyText)
}

func makeClipboardPayload(
    items: [ClipboardPasteboardItemRepresentations],
    legacyText: String? = nil,
    limits: ClipboardAttachmentLimits = .default
) -> ClipboardPayload {
    makeBoundedClipboardPayload(items: items, legacyText: legacyText, limits: limits)
}

func makeClipboardOriginalSnapshot(
    items: [ClipboardPasteboardItemRepresentations],
    legacyText: String? = nil,
    changeCount: Int? = nil,
    unsupportedRepresentationCount: Int = 0,
    limits: ClipboardAttachmentLimits = .default
) -> ClipboardOriginalSnapshot {
    var retainedImageBytes = 0
    var omittedAttachmentCount = 0
    let originalItems = items.map { item -> ClipboardOriginalItem in
        var representations: [ClipboardOriginalRepresentation] = []
        let hasAttachmentRepresentation = item.hasFileURLRepresentation ||
            item.hasPNGRepresentation || item.hasTIFFRepresentation
        var retainedAttachment = false
        if item.hasFileURLRepresentation {
            if let fileURL = item.fileURL, fileURL.isFileURL {
                representations.append(.fileURL(fileURL))
                retainedAttachment = true
            } else {
                omittedAttachmentCount += 1
            }
        }
        if item.hasPNGRepresentation {
            if let data = item.pngData,
               data.count <= limits.perImageBytes,
               retainedImageBytes + data.count <= limits.aggregateImageBytes {
                representations.append(.png(data))
                retainedImageBytes += data.count
                retainedAttachment = true
            } else {
                omittedAttachmentCount += 1
            }
        }
        if item.hasTIFFRepresentation {
            if let data = item.tiffData,
               data.count <= limits.perImageBytes,
               retainedImageBytes + data.count <= limits.aggregateImageBytes {
                representations.append(.tiff(data))
                retainedImageBytes += data.count
                retainedAttachment = true
            } else {
                omittedAttachmentCount += 1
            }
        }
        if let text = item.text,
           !hasAttachmentRepresentation || retainedAttachment {
            representations.insert(.text(text), at: 0)
        }
        return ClipboardOriginalItem(representations: representations)
    }.filter { !$0.representations.isEmpty }
    return ClipboardOriginalSnapshot(
        items: originalItems,
        legacyText: legacyText,
        changeCount: changeCount,
        omittedAttachmentCount: omittedAttachmentCount + max(0, unsupportedRepresentationCount)
    )
}

func clipboardPayloadFingerprint(_ payload: ClipboardPayload) -> String {
    payload.fingerprint
}

func areEquivalentClipboardPayloads(_ lhs: ClipboardPayload?, _ rhs: ClipboardPayload?) -> Bool {
    lhs?.fingerprint == rhs?.fingerprint
}

private func makeNativePasteboardItem(
    representations: [ClipboardOriginalRepresentation]
) -> NSPasteboardItem? {
    let item = NSPasteboardItem()
    var wroteRepresentation = false
    for representation in representations {
        switch representation {
        case .text(let text):
            wroteRepresentation = item.setString(text, forType: .string) || wroteRepresentation
        case .fileURL(let url):
            guard url.isFileURL else { continue }
            // URL metadata only; never read the referenced file.
            wroteRepresentation = item.setString(url.absoluteString, forType: .fileURL) || wroteRepresentation
        case .png(let data):
            wroteRepresentation = item.setData(data, forType: .png) || wroteRepresentation
        case .tiff(let data):
            wroteRepresentation = item.setData(data, forType: .tiff) || wroteRepresentation
        }
    }
    return wroteRepresentation ? item : nil
}

/// Removes text and unavailable markers from a selected attachment operation.
/// This is intentionally not a general payload projection: attachment handoff
/// must never degrade to an incidental or neighboring text representation.
func makeWritableAttachmentHandoffPayload(_ payload: ClipboardPayload) -> ClipboardPayload {
    ClipboardPayload(
        items: payload.items.filter { item in
            switch item {
            case .fileURL, .imagePNG, .imageTIFF:
                return true
            case .text, .unavailableImage, .unavailableFileURL:
                return false
            }
        },
        legacyText: nil
    )
}

let CLIPBOARD_FILENAMES_PASTEBOARD_TYPE = NSPasteboard.PasteboardType("NSFilenamesPboardType")

@discardableResult
func writeOrderedClipboardFileList(
    _ fileURLs: [URL],
    to pasteboard: NSPasteboard = .general
) -> Bool {
    let validFileURLs = fileURLs.filter(\.isFileURL)
    guard validFileURLs.count == fileURLs.count,
          !validFileURLs.isEmpty,
          let propertyListData = try? PropertyListSerialization.data(
            fromPropertyList: validFileURLs.map(\.path),
            format: .xml,
            options: 0
          ) else {
        return false
    }

    // Write one eager Finder file list. NSURL pasteboard writers can vend
    // their representations lazily; that makes the clipboard depend on the
    // writer remaining available and has proved unreliable for generated
    // images. macOS synthesizes the public file-URL flavors from this native
    // filename-array representation.
    pasteboard.declareTypes([CLIPBOARD_FILENAMES_PASTEBOARD_TYPE], owner: nil)
    return pasteboard.setData(
        propertyListData,
        forType: CLIPBOARD_FILENAMES_PASTEBOARD_TYPE
    )
}

private func pasteboardContainsOrderedClipboardFileList(
    _ fileURLs: [URL],
    on pasteboard: NSPasteboard
) -> Bool {
    guard fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
          let data = pasteboard.data(forType: CLIPBOARD_FILENAMES_PASTEBOARD_TYPE),
          let paths = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
          ) as? [String] else {
        return false
    }
    return paths == fileURLs.map(\.path)
}

/// An immutable, fully materialized attachment handoff. Existing file URLs are
/// borrowed; only `generatedDirectory` and the image files inside it are owned
/// by Macrowhisper.
struct PreparedClipboardAttachmentFileHandoff {
    let generationIdentifier: String
    let fileURLs: [URL]
    let generatedDirectory: URL?
    let sourceAttachmentCount: Int
    let materializedImageCount: Int
    let transcodedTIFFImageCount: Int
    let imageNormalizationFailureCount: Int
    let materializationFailureCount: Int
    let sourceImageByteCount: Int
    let generatedImageByteCount: Int

    var clipboardPayload: ClipboardPayload {
        ClipboardPayload(items: fileURLs.map(ClipboardPayloadItem.fileURL), legacyText: nil)
    }
}

enum ClipboardAttachmentCommitResult: Equatable {
    case committed
    case noWritableAttachments
    case preservedCurrentClipboard
}

private enum ClipboardAttachmentMaterializationError: Error {
    case invalidImageData
}

/// Owns the temporary files used to turn raw clipboard images into a single,
/// Finder-compatible multi-file handoff. Successful generations have a
/// retention window and current clipboard ownership extends that window, so a
/// transient pasteboard readback failure cannot immediately break the handoff.
final class ClipboardAttachmentFileStore {
    static let defaultRetentionInterval: TimeInterval = 24 * 60 * 60
    static let defaultMaxCacheBytes: Int64 = 1024 * 1024 * 1024
    private static let ownershipMarkerFilename = ".macrowhisper-clipboard-attachment-generation"

    private let fileManager: FileManager
    let rootDirectory: URL
    private let retentionInterval: TimeInterval
    private let maxCacheBytes: Int64
    private let now: () -> Date
    private let queue = DispatchQueue(label: "ClipboardMonitor.attachmentFileStore")
    private var pendingDirectoryPaths: Set<String> = []

    /// Returns whether disk cleanup could affect anything Macrowhisper owns.
    /// Nonempty UUID directories without an ownership marker are deliberately
    /// outside that boundary and do not justify probing the user's pasteboard.
    private func hasManagedCleanupCandidates() -> Bool {
        queue.sync {
            guard let children = try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return false
            }

            return children.contains { child in
                guard UUID(uuidString: child.lastPathComponent) != nil,
                      let resourceValues = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                      resourceValues.isDirectory == true else {
                    return false
                }
                let ownershipMarker = child.appendingPathComponent(
                    Self.ownershipMarkerFilename,
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: ownershipMarker.path) {
                    return true
                }
                return (try? fileManager.contentsOfDirectory(atPath: child.path).isEmpty) == true
            }
        }
    }

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        retentionInterval: TimeInterval = ClipboardAttachmentFileStore.defaultRetentionInterval,
        maxCacheBytes: Int64 = ClipboardAttachmentFileStore.defaultMaxCacheBytes,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.retentionInterval = max(0, retentionInterval)
        self.maxCacheBytes = max(0, maxCacheBytes)
        self.now = now
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return cacheRoot
            .appendingPathComponent("Macrowhisper", isDirectory: true)
            .appendingPathComponent("ClipboardAttachments", isDirectory: true)
    }

    func prepare(_ payload: ClipboardPayload) -> PreparedClipboardAttachmentFileHandoff {
        queue.sync {
            let generationIdentifier = UUID().uuidString
            var generatedDirectory: URL?
            var fileURLs: [URL] = []
            var materializedImageCount = 0
            var transcodedTIFFImageCount = 0
            var imageNormalizationFailureCount = 0
            var materializationFailureCount = 0
            var sourceImageByteCount = 0
            var generatedImageByteCount = 0

            func ensureGeneratedDirectory() throws -> URL {
                if let generatedDirectory { return generatedDirectory }
                try fileManager.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let directory = rootDirectory
                    .appendingPathComponent(generationIdentifier, isDirectory: true)
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let ownershipMarker = directory.appendingPathComponent(
                    Self.ownershipMarkerFilename,
                    isDirectory: false
                )
                guard fileManager.createFile(
                    atPath: ownershipMarker.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    try? fileManager.removeItem(at: directory)
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteUnknownError,
                        userInfo: [NSFilePathErrorKey: ownershipMarker.path]
                    )
                }
                generatedDirectory = directory
                pendingDirectoryPaths.insert(directory.standardizedFileURL.path)
                return directory
            }

            for (index, item) in payload.items.enumerated() {
                switch item {
                case .fileURL(let url):
                    guard url.isFileURL else {
                        materializationFailureCount += 1
                        continue
                    }
                    fileURLs.append(url.standardizedFileURL)

                case .imagePNG(let data):
                    sourceImageByteCount += data.count
                    do {
                        guard Self.isDecodableImageData(data) else {
                            throw ClipboardAttachmentMaterializationError.invalidImageData
                        }
                        let directory = try ensureGeneratedDirectory()
                        let fileURL = directory.appendingPathComponent(
                            String(format: "attachment-%04d.png", index + 1),
                            isDirectory: false
                        )
                        try data.write(to: fileURL, options: .atomic)
                        fileURLs.append(fileURL)
                        materializedImageCount += 1
                        generatedImageByteCount += data.count
                    } catch ClipboardAttachmentMaterializationError.invalidImageData {
                        imageNormalizationFailureCount += 1
                        materializationFailureCount += 1
                    } catch {
                        materializationFailureCount += 1
                    }

                case .imageTIFF(let data):
                    sourceImageByteCount += data.count
                    do {
                        guard let pngData = Self.pngDataByTranscodingTIFF(data),
                              pngData.count <= CLIPBOARD_MAX_IMAGE_BYTES else {
                            throw ClipboardAttachmentMaterializationError.invalidImageData
                        }
                        let directory = try ensureGeneratedDirectory()
                        let fileURL = directory.appendingPathComponent(
                            String(format: "attachment-%04d.png", index + 1),
                            isDirectory: false
                        )
                        try pngData.write(to: fileURL, options: .atomic)
                        fileURLs.append(fileURL)
                        materializedImageCount += 1
                        transcodedTIFFImageCount += 1
                        generatedImageByteCount += pngData.count
                    } catch ClipboardAttachmentMaterializationError.invalidImageData {
                        imageNormalizationFailureCount += 1
                        materializationFailureCount += 1
                    } catch {
                        materializationFailureCount += 1
                    }

                case .text:
                    break
                case .unavailableImage, .unavailableFileURL:
                    materializationFailureCount += 1
                }
            }

            if let directory = generatedDirectory,
               materializedImageCount == 0 {
                try? fileManager.removeItem(at: directory)
                pendingDirectoryPaths.remove(directory.standardizedFileURL.path)
                generatedDirectory = nil
            }

            return PreparedClipboardAttachmentFileHandoff(
                generationIdentifier: generationIdentifier,
                fileURLs: fileURLs,
                generatedDirectory: generatedDirectory,
                sourceAttachmentCount: payload.attachmentItems.count,
                materializedImageCount: materializedImageCount,
                transcodedTIFFImageCount: transcodedTIFFImageCount,
                imageNormalizationFailureCount: imageNormalizationFailureCount,
                materializationFailureCount: materializationFailureCount,
                sourceImageByteCount: sourceImageByteCount,
                generatedImageByteCount: generatedImageByteCount
            )
        }
    }

    private static func isDecodableImageData(_ data: Data) -> Bool {
        NSBitmapImageRep(data: data) != nil
    }

    /// Raw image clipboard providers commonly vend TIFF only. TIFF uploads are
    /// inconsistently accepted by paste targets, so normalize the pixels to a
    /// real PNG file before publishing the Finder-style filename list.
    private static func pngDataByTranscodingTIFF(_ data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Commits one eager Finder filename-array payload. Preparing all image files
    /// before this call keeps materialization failures from clearing the user's
    /// clipboard. The native filename-array type is deliberate: AppKit
    /// synthesizes file-URL flavors from it without a lazy writer dependency.
    @discardableResult
    func commit(
        _ handoff: PreparedClipboardAttachmentFileHandoff,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        commitResult(handoff, to: pasteboard) == .committed
    }

    func commitResult(
        _ handoff: PreparedClipboardAttachmentFileHandoff,
        to pasteboard: NSPasteboard = .general
    ) -> ClipboardAttachmentCommitResult {
        guard !handoff.fileURLs.isEmpty else {
            discard(handoff)
            return .noWritableAttachments
        }

        // `declareTypes` replaces the pasteboard before `setData` reports
        // success. Refuse to make that destructive transition unless the
        // currently supported clipboard state was captured stably and can be
        // restored if the filename-array write unexpectedly fails.
        guard let previousSnapshot = captureClipboardPasteboardSnapshot(
            from: pasteboard,
            source: "attachment-handoff-precommit",
            includeAttachments: true,
            captureOriginalSnapshot: true
        )?.originalSnapshot,
        previousSnapshot.isComplete else {
            logWarning(
                "[ClipboardMonitor] Attachment handoff commit skipped " +
                "(reason: unstable-or-incomplete-precommit-snapshot)"
            )
            discard(handoff)
            return .preservedCurrentClipboard
        }

        // Exercise the exact serialization on an isolated pasteboard before
        // touching the user's clipboard. This catches malformed or rejected
        // filename arrays without changing the general pasteboard.
        let stagingPasteboard = NSPasteboard.withUniqueName()
        guard writeOrderedClipboardFileList(handoff.fileURLs, to: stagingPasteboard) else {
            logWarning(
                "[ClipboardMonitor] Attachment handoff commit skipped " +
                "(reason: filename-array-preflight-failed)"
            )
            discard(handoff)
            return .preservedCurrentClipboard
        }

        guard pasteboard.changeCount == previousSnapshot.changeCount else {
            logWarning(
                "[ClipboardMonitor] Attachment handoff commit skipped " +
                "(reason: clipboard-changed-during-preflight)"
            )
            discard(handoff)
            return .preservedCurrentClipboard
        }

        let didWrite = writeOrderedClipboardFileList(handoff.fileURLs, to: pasteboard)
        let didVerify = didWrite && pasteboardContainsOrderedClipboardFileList(
            handoff.fileURLs,
            on: pasteboard
        )
        let didCommit = didWrite && didVerify
        if !didCommit {
            let didRecover = writeClipboardOriginalSnapshotNatively(previousSnapshot, to: pasteboard)
            logWarning(
                "[ClipboardMonitor] Attachment handoff commit failed " +
                "(reason: \(didWrite ? "post-write-verification-failed" : "general-pasteboard-write-rejected"), " +
                "recoveredPreviousClipboard: \(didRecover))"
            )
        }
        finish(handoff, didWrite: didCommit)
        return didCommit ? .committed : .preservedCurrentClipboard
    }

    func discard(_ handoff: PreparedClipboardAttachmentFileHandoff) {
        finish(handoff, didWrite: false)
    }

    private func finish(
        _ handoff: PreparedClipboardAttachmentFileHandoff,
        didWrite: Bool
    ) {
        queue.sync {
            guard let directory = handoff.generatedDirectory else { return }
            pendingDirectoryPaths.remove(directory.standardizedFileURL.path)
            if !didWrite {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    /// Deletes expired or over-capacity Macrowhisper-owned generations that are
    /// neither pending nor referenced by an existing current-clipboard file. It
    /// also reclaims expired empty UUID directories left if generation creation
    /// was interrupted before its ownership marker was written. Borrowed user
    /// files are never inside `rootDirectory` and are never deletion targets.
    @discardableResult
    func cleanupUnused(pasteboard: NSPasteboard = .general) -> Int {
        guard hasManagedCleanupCandidates() else { return 0 }

        let initialChangeCount = pasteboard.changeCount
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let currentFileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []).compactMap { ($0 as? NSURL) as URL? }
        let advertisesEagerFileList = pasteboard.types?.contains(
            CLIPBOARD_FILENAMES_PASTEBOARD_TYPE
        ) == true
        let eagerFilenameData = pasteboard.data(
            forType: CLIPBOARD_FILENAMES_PASTEBOARD_TYPE
        )
        let eagerFilenamePaths: [String]? = eagerFilenameData.flatMap { data in
            try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String]
        }
        guard pasteboard.changeCount == initialChangeCount else {
            logDebug(
                "[ClipboardMonitor] Attachment cache cleanup skipped " +
                "(reason: clipboard-changed-during-read)"
            )
            return 0
        }
        guard !advertisesEagerFileList || eagerFilenamePaths != nil else {
            if shouldEmitRateLimitedLog(
                key: "ClipboardMonitor.attachmentCleanup.advertisedFileListUnavailable",
                cooldown: 60 * 60
            ) {
                logDebug(
                    "[ClipboardMonitor] Attachment cache cleanup deferred safely " +
                    "(reason: advertised-file-list-unavailable, changeCount: \(initialChangeCount))"
                )
            }
            return 0
        }
        let eagerFilenameURLs = (eagerFilenamePaths ?? []).map {
            URL(fileURLWithPath: $0)
        }
        let preservedFileURLs = currentFileURLs + eagerFilenameURLs
        let removedCount = cleanupUnused(
            preserving: preservedFileURLs,
            validateBeforeRemoval: {
                // Narrow the remaining pasteboard race by revalidating
                // immediately before every destructive filesystem operation.
                pasteboard.changeCount == initialChangeCount
            }
        )
        if removedCount > 0 {
            logDebug(
                "[ClipboardMonitor] Attachment cache cleanup removed expired or over-capacity generations " +
                "(removedGenerations: \(removedCount), preservedClipboardFiles: \(Set(preservedFileURLs).count))"
            )
        }
        return removedCount
    }

    @discardableResult
    func cleanupUnused(
        preserving fileURLs: [URL],
        validateBeforeRemoval: () -> Bool = { true }
    ) -> Int {
        queue.sync {
            let rootPath = rootDirectory.standardizedFileURL.path
            let expirationCutoff = now().addingTimeInterval(-retentionInterval)

            func referencedDirectoryPath(for url: URL) -> String? {
                guard url.isFileURL else { return nil }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { return nil }
                let relativePath = String(path.dropFirst(rootPath.count + 1))
                let components = relativePath.split(separator: "/")
                guard components.count >= 2,
                      let firstComponent = components.first,
                      UUID(uuidString: String(firstComponent)) != nil else {
                    return nil
                }
                return rootDirectory
                    .appendingPathComponent(String(firstComponent), isDirectory: true)
                    .standardizedFileURL.path
            }

            let referencedDirectoryPaths = Set(fileURLs.compactMap(referencedDirectoryPath))
            let preservedDirectoryPaths: Set<String> = Set(fileURLs.compactMap { url in
                guard let directoryPath = referencedDirectoryPath(for: url) else { return nil }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    return nil
                }
                let ownershipMarkerPath = URL(fileURLWithPath: directoryPath, isDirectory: true)
                    .appendingPathComponent(Self.ownershipMarkerFilename, isDirectory: false)
                    .path
                guard fileManager.fileExists(atPath: ownershipMarkerPath) else { return nil }
                return directoryPath
            })
            let staleReferencedGenerationCount = referencedDirectoryPaths
                .subtracting(preservedDirectoryPaths)
                .count
            if staleReferencedGenerationCount > 0 {
                logDebug(
                    "[ClipboardMonitor] Attachment cache ignored stale clipboard generation references " +
                    "(staleGenerations: \(staleReferencedGenerationCount))"
                )
            }

            // Do not even extend a generation's retention window from a stale
            // clipboard snapshot. The caller reuses this same validation before
            // every destructive removal below.
            guard validateBeforeRemoval() else { return 0 }

            // Refresh the retention anchor while a generation is still owned
            // by the clipboard. Its full retention window therefore starts
            // after the last observation of that ownership, not merely when
            // the image was first materialized.
            let observedAt = now()
            for directoryPath in preservedDirectoryPaths {
                try? fileManager.setAttributes(
                    [.modificationDate: observedAt],
                    ofItemAtPath: directoryPath
                )
            }

            guard let children = try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .creationDateKey
                ],
                options: [.skipsHiddenFiles]
            ) else {
                return 0
            }

            struct StoredGeneration {
                let url: URL
                let path: String
                let retainedAt: Date
                let byteCount: Int64
            }

            func storedByteCount(in directory: URL) -> Int64 {
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .totalFileAllocatedSizeKey,
                        .fileSizeKey
                    ],
                    options: [.skipsHiddenFiles]
                ) else {
                    return 0
                }
                var total: Int64 = 0
                for case let file as URL in enumerator {
                    guard let values = try? file.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .totalFileAllocatedSizeKey,
                        .fileSizeKey
                    ]), values.isRegularFile == true else {
                        continue
                    }
                    let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    let (sum, overflowed) = total.addingReportingOverflow(max(0, bytes))
                    total = overflowed ? Int64.max : sum
                }
                return total
            }

            var generations: [StoredGeneration] = []
            var abandonedEmptyDirectories: [StoredGeneration] = []
            for child in children {
                let childPath = child.standardizedFileURL.path
                let ownershipMarker = child.appendingPathComponent(
                    Self.ownershipMarkerFilename,
                    isDirectory: false
                )
                guard UUID(uuidString: child.lastPathComponent) != nil else { continue }
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .creationDateKey
                ])
                guard values?.isDirectory == true,
                      let retainedAt = values?.contentModificationDate ?? values?.creationDate else {
                    continue
                }
                let storedGeneration = StoredGeneration(
                    url: child,
                    path: childPath,
                    retainedAt: retainedAt,
                    byteCount: storedByteCount(in: child)
                )
                guard fileManager.fileExists(atPath: ownershipMarker.path) else {
                    // A process death between directory creation and marker
                    // creation can leave an empty UUID directory. Reclaim only
                    // empty, expired directories; nonempty unmarked directories
                    // remain outside Macrowhisper's ownership boundary.
                    if let contents = try? fileManager.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: nil,
                        options: []
                    ), contents.isEmpty {
                        abandonedEmptyDirectories.append(storedGeneration)
                    }
                    continue
                }
                generations.append(storedGeneration)
            }

            var removedPaths: Set<String> = []
            var removedCount = 0
            var retainedByteCount = generations.reduce(Int64(0)) { partial, generation in
                let (sum, overflowed) = partial.addingReportingOverflow(generation.byteCount)
                return overflowed ? Int64.max : sum
            }

            for abandoned in abandonedEmptyDirectories where
                !pendingDirectoryPaths.contains(abandoned.path) &&
                !preservedDirectoryPaths.contains(abandoned.path) &&
                abandoned.retainedAt <= expirationCutoff {
                guard validateBeforeRemoval() else { return removedCount }
                if (try? fileManager.removeItem(at: abandoned.url)) != nil {
                    removedCount += 1
                }
            }

            for generation in generations where
                !pendingDirectoryPaths.contains(generation.path) &&
                !preservedDirectoryPaths.contains(generation.path) &&
                generation.retainedAt <= expirationCutoff {
                guard validateBeforeRemoval() else { return removedCount }
                if (try? fileManager.removeItem(at: generation.url)) != nil {
                    removedPaths.insert(generation.path)
                    removedCount += 1
                    retainedByteCount = max(0, retainedByteCount - generation.byteCount)
                }
            }

            if retainedByteCount > maxCacheBytes {
                let capacityCandidates = generations
                    .filter {
                        !removedPaths.contains($0.path) &&
                        !pendingDirectoryPaths.contains($0.path) &&
                        !preservedDirectoryPaths.contains($0.path)
                    }
                    .sorted { lhs, rhs in
                        if lhs.retainedAt == rhs.retainedAt {
                            return lhs.path < rhs.path
                        }
                        return lhs.retainedAt < rhs.retainedAt
                    }
                for generation in capacityCandidates where retainedByteCount > maxCacheBytes {
                    guard validateBeforeRemoval() else { return removedCount }
                    if (try? fileManager.removeItem(at: generation.url)) != nil {
                        removedCount += 1
                        retainedByteCount = max(0, retainedByteCount - generation.byteCount)
                    }
                }
            }
            return removedCount
        }
    }
}

/// Restores all supported representations in their original pasteboard-item
/// order. File URL entries remain URL metadata and are never read.
@discardableResult
func writeClipboardOriginalSnapshot(
    _ snapshot: ClipboardOriginalSnapshot?,
    to pasteboard: NSPasteboard = .general
) -> Bool {
    guard let snapshot else {
        // Nil means the capture was unavailable or unstable, not that the
        // clipboard was empty. A successfully captured empty clipboard is a
        // non-nil snapshot with `isEmpty == true`.
        return false
    }
    guard snapshot.isComplete else { return false }
    let fileURLsOnly: [URL]? = {
        var fileURLs: [URL] = []
        for item in snapshot.items {
            guard item.representations.count == 1,
                  case .fileURL(let url) = item.representations[0],
                  url.isFileURL else {
                return nil
            }
            fileURLs.append(url)
        }
        return fileURLs.isEmpty ? nil : fileURLs
    }()
    if let fileURLsOnly {
        return writeOrderedClipboardFileList(fileURLsOnly, to: pasteboard)
    }
    let nativeItems = snapshot.items.compactMap {
        makeNativePasteboardItem(representations: $0.representations)
    }
    guard !nativeItems.isEmpty else {
        if snapshot.isEmpty {
            pasteboard.clearContents()
            return true
        }
        return false
    }
    pasteboard.clearContents()
    return pasteboard.writeObjects(nativeItems)
}

/// Representation-native restoration used only as the recovery path after an
/// eager filename-array write fails. Keeping it separate avoids retrying the
/// same failed writer while the user's previous clipboard is being recovered.
@discardableResult
private func writeClipboardOriginalSnapshotNatively(
    _ snapshot: ClipboardOriginalSnapshot,
    to pasteboard: NSPasteboard
) -> Bool {
    guard snapshot.isComplete else { return false }
    let nativeItems = snapshot.items.compactMap {
        makeNativePasteboardItem(representations: $0.representations)
    }
    guard !nativeItems.isEmpty else {
        if snapshot.isEmpty {
            pasteboard.clearContents()
            return true
        }
        return false
    }
    pasteboard.clearContents()
    return pasteboard.writeObjects(nativeItems)
}

struct ClipboardImageRetentionBudgetResult: Equatable {
    let payloads: [ClipboardPayload]
    let retainedImageBytes: Int
    let droppedImageCount: Int
}

/// Applies the monitor-wide image budget in capture order. Unprotected
/// (pre-recording) payloads are evicted before protected active/original
/// payloads; dropped images remain attachment-classified.
func applyClipboardImageRetentionBudget(
    to payloads: [ClipboardPayload],
    protectedIndices: Set<Int> = [],
    limits: ClipboardAttachmentLimits = .default
) -> ClipboardImageRetentionBudgetResult {
    var bounded = payloads
    var retained = bounded.reduce(0) { $0 + $1.retainedImageByteCount }
    var droppedCount = 0
    guard retained > limits.aggregateImageBytes else {
        return ClipboardImageRetentionBudgetResult(
            payloads: bounded,
            retainedImageBytes: retained,
            droppedImageCount: 0
        )
    }

    let unprotected = bounded.indices.filter { !protectedIndices.contains($0) }
    let protected = bounded.indices.filter { protectedIndices.contains($0) }
    for index in unprotected + protected {
        guard retained > limits.aggregateImageBytes else { break }
        let before = bounded[index].retainedImageByteCount
        guard before > 0 else { continue }
        bounded[index] = bounded[index].droppingRetainedImages(reason: .aggregateLimit)
        retained -= before
        droppedCount += bounded[index].unavailableAttachmentCount
    }
    return ClipboardImageRetentionBudgetResult(
        payloads: bounded,
        retainedImageBytes: max(0, retained),
        droppedImageCount: droppedCount
    )
}

struct ClipboardContextSnapshot: Equatable {
    let representations: ClipboardContextRepresentations
    let orderedPayloads: [ClipboardPayload]
    let attachmentCandidates: [ClipboardPayload]

    /// The attachment candidates are a filtered view of `orderedPayloads`, so
    /// count them once when applying the monitor-wide retention budget.
    var retainedImageByteCount: Int {
        attachmentCandidates.reduce(0) { $0 + $1.retainedImageByteCount }
    }

    var latestAttachmentCandidate: ClipboardPayload? { attachmentCandidates.last }
    var latestEligibleOperation: ClipboardPayload? { orderedPayloads.last }

    /// Attachment handoff selection mirrors clipboard stacking: off selects
    /// only the latest eligible operation, while on retains every attachment
    /// operation in capture order.
    var singleAttachmentCandidates: [ClipboardPayload] {
        guard let latestEligibleOperation, latestEligibleOperation.hasAttachments else { return [] }
        return [latestEligibleOperation]
    }

    var stackedAttachmentCandidates: [ClipboardPayload] { attachmentCandidates }
}

enum ClipboardAttachmentHandoffConsumer: String, Equatable {
    case none
    case actionExecutor
    case watcher
    case explicit
}

/// Attachment handoff is an explicit root-action capability, independent of
/// whether that action also consumes the string-only clipboardContext value.
func shouldEnableAttachmentHandoffForExecution(attachmentsEnabled: Bool) -> Bool {
    attachmentsEnabled
}

struct ClipboardAttachmentHandoffPolicy: Equatable {
    let enabled: Bool
    let consumer: ClipboardAttachmentHandoffConsumer
    let wholeChainSucceeded: Bool
    let priorChainFailure: Bool

    static let disabled = ClipboardAttachmentHandoffPolicy(
        enabled: false,
        consumer: .none,
        wholeChainSucceeded: false,
        priorChainFailure: false
    )

    init(
        enabled: Bool,
        consumer: ClipboardAttachmentHandoffConsumer = .explicit,
        wholeChainSucceeded: Bool = true,
        priorChainFailure: Bool = false
    ) {
        self.enabled = enabled
        self.consumer = consumer
        self.wholeChainSucceeded = wholeChainSucceeded
        self.priorChainFailure = priorChainFailure
    }

    var isEligible: Bool {
        enabled && consumer != .none && wholeChainSucceeded && !priorChainFailure
    }
}

func updatedClipboardAttachmentHandoffPolicy(
    existing: ClipboardAttachmentHandoffPolicy,
    consumer: ClipboardAttachmentHandoffConsumer,
    wholeChainSucceeded: Bool,
    priorChainFailure: Bool
) -> ClipboardAttachmentHandoffPolicy {
    let stickyPriorFailure = priorChainFailure || existing.priorChainFailure
    return ClipboardAttachmentHandoffPolicy(
        enabled: true,
        consumer: consumer,
        wholeChainSucceeded: wholeChainSucceeded && !stickyPriorFailure,
        priorChainFailure: stickyPriorFailure
    )
}

// Known pasteboard marker types to ignore
private let TRANSIENT_MARKER_TYPES: [NSPasteboard.PasteboardType] = [
    NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
    NSPasteboard.PasteboardType("com.typeit4me.clipping"),
    NSPasteboard.PasteboardType("Pasteboard generator type"),
    NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"), // Often used with transient data
    NSPasteboard.PasteboardType("com.apple.is-remote-clipboard") // Handoff content is often transient
]

private let CONCEALED_MARKER_TYPES: [NSPasteboard.PasteboardType] = [
    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    NSPasteboard.PasteboardType("com.agilebits.onepassword")
]

/// Time window for retroactive clipboard cleanup when ignored apps become frontmost
/// This handles cases where apps trigger clipboard changes before gaining focus (e.g., during window activation)
private let RETROACTIVE_CLEANUP_WINDOW: TimeInterval = 0.5  // Look back 0.5 seconds for cleanup
private let DEFAULT_CLIPBOARD_RESTORE_DELAY: TimeInterval = 0.3
private let CLIPBOARD_CLEANUP_GRACE: TimeInterval = 0.2
private let STARTUP_CLIPBOARD_REPLAY_LOOKBACK: TimeInterval = 3.0
private let STARTUP_CLIPBOARD_REPLAY_FORWARD_WINDOW: TimeInterval = 5.0
private let MAX_EXECUTION_GROUP_JOIN_AGE: TimeInterval = 10.0
let IGNORED_MARKER_FOLLOW_UP_WINDOW: TimeInterval = 1.5
let IGNORED_MARKER_COUNT_RETENTION: TimeInterval = 5.0
private let MAX_IGNORED_MARKER_CHANGE_COUNTS = 64
let INFERRED_TRANSIENT_RESTORE_WINDOW: TimeInterval = 1.5
let MIN_INFERRED_TRANSIENT_INITIAL_COUNT_DELTA = 3
let ADJACENT_STARTUP_TRANSIENT_CANDIDATE_WINDOW: TimeInterval = 1.0
let ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW: TimeInterval = 0.5

struct StartupClipboardBootstrapState: Equatable {
    let stableGlobalChangeCount: Int
    let stableGlobalPayloadFingerprint: String
    let stableGlobalLastChangeObservedAt: Date?
    let sessionSnapshotChangeCount: Int
    let sessionSnapshotPayloadFingerprint: String
    let sessionSnapshotObservedAt: Date
}

enum StartupClipboardBootstrapRestoreDecision: String, Equatable {
    case capture
    case ignoreRestoredStableClipboard
}

/// Recognizes the startup ordering where monitoring's stable clipboard is X,
/// Superwhisper temporarily replaces it with Y while the recording session is
/// being initialized, and the first session observation is the restoration to X.
/// Exact adjacent counts and payload fingerprints keep this narrower than a
/// general startup blackout, so genuine copies remain eligible.
/// The stable value itself may legitimately be old (it had been unchanged for
/// several minutes in the motivating trace), so its last-change age is logged
/// for diagnosis but is not used as a freshness gate.
func evaluateStartupClipboardBootstrapRestore(
    state: StartupClipboardBootstrapState?,
    sessionStartInputFieldState: SessionStartInputFieldState,
    sessionStartTime: Date,
    observedAt: Date,
    observedChangeCount: Int,
    observedPayloadFingerprint: String,
    candidateWindow: TimeInterval = ADJACENT_STARTUP_TRANSIENT_CANDIDATE_WINDOW,
    restoreWindow: TimeInterval = ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW
) -> StartupClipboardBootstrapRestoreDecision {
    guard sessionStartInputFieldState == .outsideInputField,
          let state,
          state.sessionSnapshotObservedAt >= sessionStartTime,
          state.sessionSnapshotObservedAt <= sessionStartTime.addingTimeInterval(max(0, candidateWindow)),
          observedAt >= state.sessionSnapshotObservedAt,
          observedAt <= state.sessionSnapshotObservedAt.addingTimeInterval(max(0, restoreWindow)),
          state.stableGlobalPayloadFingerprint != state.sessionSnapshotPayloadFingerprint,
          state.stableGlobalPayloadFingerprint == observedPayloadFingerprint else {
        return .capture
    }

    let sessionCount = state.stableGlobalChangeCount.addingReportingOverflow(1)
    let restoredCount = state.sessionSnapshotChangeCount.addingReportingOverflow(1)
    guard !sessionCount.overflow,
          !restoredCount.overflow,
          state.sessionSnapshotChangeCount == sessionCount.partialValue,
          observedChangeCount == restoredCount.partialValue else {
        return .capture
    }

    return .ignoreRestoredStableClipboard
}

enum IgnoredClipboardMarkerSequenceDecision: String, Equatable {
    case capture
    case ignoreMarker
    case ignoreFollowUp
    case ignorePreviouslyClassified

    var shouldIgnore: Bool {
        self != .capture
    }
}

/// Correlates the short sequence of pasteboard writes produced by transient and
/// concealed clipboard operations. Some providers first publish a marked item,
/// then immediately redeclare the same payload (or restore the prior payload)
/// without carrying the marker onto the second change count.
struct IgnoredClipboardMarkerSequenceTracker {
    private var pendingSuccessor: (changeCount: Int, markerObservedAt: Date)?
    private var ignoredChangeCounts: [Int: Date] = [:]

    mutating func reset() {
        pendingSuccessor = nil
        ignoredChangeCounts.removeAll()
    }

    private mutating func recordIgnoredChangeCount(_ changeCount: Int, observedAt: Date) {
        ignoredChangeCounts[changeCount] = observedAt
        guard ignoredChangeCounts.count > MAX_IGNORED_MARKER_CHANGE_COUNTS else { return }

        let excessCount = ignoredChangeCounts.count - MAX_IGNORED_MARKER_CHANGE_COUNTS
        let oldestChangeCounts = ignoredChangeCounts
            .sorted { $0.value < $1.value }
            .prefix(excessCount)
            .map(\.key)
        for oldChangeCount in oldestChangeCounts {
            ignoredChangeCounts.removeValue(forKey: oldChangeCount)
        }
    }

    mutating func decision(
        changeCount: Int,
        containsIgnoredMarker: Bool,
        observedAt: Date,
        followUpWindow: TimeInterval = IGNORED_MARKER_FOLLOW_UP_WINDOW,
        ignoredCountRetention: TimeInterval = IGNORED_MARKER_COUNT_RETENTION
    ) -> IgnoredClipboardMarkerSequenceDecision {
        let boundedRetention = max(0, ignoredCountRetention)
        ignoredChangeCounts = ignoredChangeCounts.filter {
            observedAt.timeIntervalSince($0.value) <= boundedRetention
        }

        let boundedFollowUpWindow = max(0, followUpWindow)
        if let pendingSuccessor,
           observedAt.timeIntervalSince(pendingSuccessor.markerObservedAt) > boundedFollowUpWindow {
            self.pendingSuccessor = nil
        }

        if ignoredChangeCounts[changeCount] != nil {
            return .ignorePreviouslyClassified
        }

        if containsIgnoredMarker {
            let successorCount = changeCount == Int.max ? Int.max : changeCount + 1
            if pendingSuccessor?.markerObservedAt ?? .distantPast <= observedAt {
                pendingSuccessor = (successorCount, observedAt)
            }
            recordIgnoredChangeCount(changeCount, observedAt: observedAt)
            return .ignoreMarker
        }

        guard let pendingSuccessor else {
            return .capture
        }
        guard observedAt >= pendingSuccessor.markerObservedAt,
              changeCount >= pendingSuccessor.changeCount else {
            return .capture
        }
        self.pendingSuccessor = nil
        guard changeCount == pendingSuccessor.changeCount else {
            return .capture
        }

        recordIgnoredChangeCount(changeCount, observedAt: observedAt)
        return .ignoreFollowUp
    }
}

enum InferredTransientRestoreDecision: Equatable {
    case capture
    case captureCandidate(changeCount: Int)
    case ignoreTransaction(candidateChangeCount: Int, restoreChangeCount: Int)
    case ignorePreviouslyClassified(candidateChangeCount: Int, restoreChangeCount: Int)

    var shouldIgnore: Bool {
        switch self {
        case .ignoreTransaction, .ignorePreviouslyClassified:
            return true
        case .capture, .captureCandidate:
            return false
        }
    }

    var transactionChangeCounts: Set<Int> {
        switch self {
        case .ignoreTransaction(let candidateChangeCount, let restoreChangeCount),
             .ignorePreviouslyClassified(let candidateChangeCount, let restoreChangeCount):
            return [candidateChangeCount, restoreChangeCount]
        case .capture, .captureCandidate:
            return []
        }
    }
}

/// Recognizes a narrowly bounded clipboard transaction whose marked states were
/// missed between polls: stable X, changed Y after at least two unseen writes,
/// then a prompt return to X. The candidate Y remains capturable unless that
/// exact restoration arrives.
struct InferredTransientRestoreTracker {
    private struct PendingCandidate {
        let changeCount: Int
        let baselineContent: String
        let baselineFingerprint: String?
        let observedAt: Date
        let restoreWindow: TimeInterval
    }

    private struct IgnoredTransaction {
        let candidateChangeCount: Int
        let restoreChangeCount: Int
        let classifiedAt: Date
    }

    private var pendingCandidate: PendingCandidate?
    private var ignoredTransactionsByChangeCount: [Int: IgnoredTransaction] = [:]

    mutating func reset() {
        pendingCandidate = nil
        ignoredTransactionsByChangeCount.removeAll()
    }

    mutating func cancelPendingCandidate(
        boundaryChangeCount: Int,
        observedAt: Date
    ) {
        guard let pendingCandidate,
              boundaryChangeCount >= pendingCandidate.changeCount,
              observedAt >= pendingCandidate.observedAt else {
            return
        }
        self.pendingCandidate = nil
    }

    /// Makes an already-classified transaction visible to both samplers. This
    /// is used when the faster session sampler classifies a startup restore
    /// before the global sampler has observed that restore change count.
    mutating func recordIgnoredTransaction(
        candidateChangeCount: Int,
        restoreChangeCount: Int,
        classifiedAt: Date
    ) {
        let transaction = IgnoredTransaction(
            candidateChangeCount: candidateChangeCount,
            restoreChangeCount: restoreChangeCount,
            classifiedAt: classifiedAt
        )
        ignoredTransactionsByChangeCount[candidateChangeCount] = transaction
        ignoredTransactionsByChangeCount[restoreChangeCount] = transaction
        pendingCandidate = nil
    }

    mutating func decision(
        changeCount: Int,
        content: String?,
        containsIgnoredMarker: Bool,
        observedAt: Date,
        previousChangeCount: Int,
        previousContent: String?,
        payloadFingerprint: String? = nil,
        previousPayloadFingerprint: String? = nil,
        restoreWindow: TimeInterval = INFERRED_TRANSIENT_RESTORE_WINDOW,
        minimumInitialCountDelta: Int = MIN_INFERRED_TRANSIENT_INITIAL_COUNT_DELTA,
        canArmCandidate: Bool = true,
        allowAdjacentInitialCount: Bool = false,
        ignoredCountRetention: TimeInterval = IGNORED_MARKER_COUNT_RETENTION
    ) -> InferredTransientRestoreDecision {
        let boundedRetention = max(0, ignoredCountRetention)
        ignoredTransactionsByChangeCount = ignoredTransactionsByChangeCount.filter {
            observedAt.timeIntervalSince($0.value.classifiedAt) <= boundedRetention
        }

        if let ignoredTransaction = ignoredTransactionsByChangeCount[changeCount] {
            return .ignorePreviouslyClassified(
                candidateChangeCount: ignoredTransaction.candidateChangeCount,
                restoreChangeCount: ignoredTransaction.restoreChangeCount
            )
        }

        if let pendingCandidate {
            if changeCount == pendingCandidate.changeCount {
                return .captureCandidate(changeCount: changeCount)
            }

            // The global and session samplers can reach this shared tracker out of
            // order. An older queued observation must not consume a newer candidate.
            if changeCount < pendingCandidate.changeCount || observedAt < pendingCandidate.observedAt {
                return .capture
            }

            let elapsed = observedAt.timeIntervalSince(pendingCandidate.observedAt)
            let restoreDeltaResult = changeCount.subtractingReportingOverflow(pendingCandidate.changeCount)
            let restoreDelta = restoreDeltaResult.overflow ? nil : restoreDeltaResult.partialValue
            let isPromptRestore = elapsed >= 0 && elapsed <= pendingCandidate.restoreWindow
            let isExactSuccessor = restoreDelta == 1
            let restoresBaseline: Bool
            if let pendingFingerprint = pendingCandidate.baselineFingerprint,
               let payloadFingerprint {
                restoresBaseline = pendingFingerprint == payloadFingerprint
            } else {
                restoresBaseline = content == pendingCandidate.baselineContent
            }

            self.pendingCandidate = nil
            if isPromptRestore && isExactSuccessor && restoresBaseline {
                let transaction = IgnoredTransaction(
                    candidateChangeCount: pendingCandidate.changeCount,
                    restoreChangeCount: changeCount,
                    classifiedAt: observedAt
                )
                ignoredTransactionsByChangeCount[pendingCandidate.changeCount] = transaction
                ignoredTransactionsByChangeCount[changeCount] = transaction
                return .ignoreTransaction(
                    candidateChangeCount: pendingCandidate.changeCount,
                    restoreChangeCount: changeCount
                )
            }
        }

        guard canArmCandidate else {
            return .capture
        }

        guard !containsIgnoredMarker,
              (content != nil || payloadFingerprint != nil),
              (previousContent != nil || previousPayloadFingerprint != nil) else {
            return .capture
        }

        if let content, let previousContent,
           payloadFingerprint == nil, previousPayloadFingerprint == nil,
           content == previousContent {
            return .capture
        }
        if let payloadFingerprint,
           let previousPayloadFingerprint,
           payloadFingerprint == previousPayloadFingerprint {
            return .capture
        }

        let initialDeltaResult = changeCount.subtractingReportingOverflow(previousChangeCount)
        guard !initialDeltaResult.overflow else {
            return .capture
        }
        let initialDeltaIsEligible = allowAdjacentInitialCount
            ? initialDeltaResult.partialValue == 1
            : initialDeltaResult.partialValue >= max(2, minimumInitialCountDelta)
        guard initialDeltaIsEligible else {
            return .capture
        }

        pendingCandidate = PendingCandidate(
            changeCount: changeCount,
            baselineContent: previousContent ?? "",
            baselineFingerprint: previousPayloadFingerprint,
            observedAt: observedAt,
            restoreWindow: max(0, restoreWindow)
        )
        return .captureCandidate(changeCount: changeCount)
    }

    mutating func isIgnored(
        changeCount: Int,
        observedAt: Date = Date(),
        ignoredCountRetention: TimeInterval = IGNORED_MARKER_COUNT_RETENTION
    ) -> Bool {
        let boundedRetention = max(0, ignoredCountRetention)
        ignoredTransactionsByChangeCount = ignoredTransactionsByChangeCount.filter {
            observedAt.timeIntervalSince($0.value.classifiedAt) <= boundedRetention
        }
        return ignoredTransactionsByChangeCount[changeCount] != nil
    }
}

struct ClipboardPasteboardSnapshot {
    let changeCount: Int
    let content: String?
    let types: [NSPasteboard.PasteboardType]
    let payload: ClipboardPayload
    let originalSnapshot: ClipboardOriginalSnapshot?
}

struct ClipboardObservationDiagnosticMetadata: Equatable {
    let changeCount: Int
    let previousChangeCount: Int?
    let changeCountDelta: Int?
    let elapsedMilliseconds: Int?
    let contentLength: Int?
    let contentToken: String
    let matchesPreviousContent: Bool?
    let pasteboardTypes: [String]
}

/// Creates a process-local correlation token so logs can connect repeated
/// clipboard payloads without recording the clipboard text itself.
func clipboardDiagnosticContentToken(_ content: String?) -> String {
    guard let content else { return "none" }
    var hasher = Hasher()
    hasher.combine(content)
    return String(UInt(bitPattern: hasher.finalize()), radix: 16)
}

func makeClipboardObservationDiagnosticMetadata(
    changeCount: Int,
    previousChangeCount: Int?,
    observedAt: Date,
    previousObservedAt: Date?,
    content: String?,
    previousContent: String?,
    pasteboardTypes: [String]
) -> ClipboardObservationDiagnosticMetadata {
    let changeCountDelta = previousChangeCount.flatMap { previousCount -> Int? in
        let subtraction = changeCount.subtractingReportingOverflow(previousCount)
        return subtraction.overflow ? nil : subtraction.partialValue
    }
    let elapsedMilliseconds = previousObservedAt.map {
        Int((observedAt.timeIntervalSince($0) * 1_000).rounded())
    }
    let matchesPreviousContent = content.flatMap { currentContent in
        previousContent.map { currentContent == $0 }
    }

    return ClipboardObservationDiagnosticMetadata(
        changeCount: changeCount,
        previousChangeCount: previousChangeCount,
        changeCountDelta: changeCountDelta,
        elapsedMilliseconds: elapsedMilliseconds,
        contentLength: content?.count,
        contentToken: clipboardDiagnosticContentToken(content),
        matchesPreviousContent: matchesPreviousContent,
        pasteboardTypes: pasteboardTypes.sorted()
    )
}

func clipboardObservationDiagnosticLogMessage(
    source: String,
    metadata: ClipboardObservationDiagnosticMetadata
) -> String {
    let previousChangeCount = metadata.previousChangeCount.map(String.init) ?? "none"
    let changeCountDelta = metadata.changeCountDelta.map(String.init) ?? "unknown"
    let elapsedMilliseconds = metadata.elapsedMilliseconds.map(String.init) ?? "unknown"
    let contentLength = metadata.contentLength.map(String.init) ?? "none"
    let matchesPreviousContent = metadata.matchesPreviousContent.map(String.init) ?? "unknown"
    let hasUnobservedChanges = metadata.changeCountDelta.map { $0 > 1 } ?? false

    return "[ClipboardMonitor] Clipboard diagnostic source=\(source) " +
        "changeCount=\(metadata.changeCount) previousChangeCount=\(previousChangeCount) " +
        "delta=\(changeCountDelta) gap=\(hasUnobservedChanges) elapsedMs=\(elapsedMilliseconds) " +
        "contentLength=\(contentLength) contentToken=\(metadata.contentToken) " +
        "matchesPreviousContent=\(matchesPreviousContent) types=\(metadata.pasteboardTypes)"
}

struct ClipboardPayloadDiagnosticMetadata: Equatable {
    let kind: ClipboardPayloadKind
    let orderedItemCount: Int
    let attachmentCount: Int
    let retainedImageBytes: Int
    let unavailableAttachmentCount: Int
    let fingerprint: String
    let dropReasons: [String]
}

func makeClipboardPayloadDiagnosticMetadata(
    _ payload: ClipboardPayload
) -> ClipboardPayloadDiagnosticMetadata {
    ClipboardPayloadDiagnosticMetadata(
        kind: payload.kind,
        orderedItemCount: payload.items.count,
        attachmentCount: payload.attachmentItems.count,
        retainedImageBytes: payload.retainedImageByteCount,
        unavailableAttachmentCount: payload.unavailableAttachmentCount,
        fingerprint: payload.fingerprint,
        dropReasons: payload.items.compactMap { item in
            if case .unavailableImage(_, _, let reason) = item { return reason.rawValue }
            if case .unavailableFileURL = item { return ClipboardAttachmentDropReason.invalidFileURL.rawValue }
            return nil
        }
    )
}

func clipboardPayloadDiagnosticLogMessage(
    source: String,
    metadata: ClipboardPayloadDiagnosticMetadata
) -> String {
    "[ClipboardMonitor] Clipboard payload source=\(source) kind=\(metadata.kind.rawValue) " +
        "items=\(metadata.orderedItemCount) attachments=\(metadata.attachmentCount) " +
        "retainedImageBytes=\(metadata.retainedImageBytes) unavailableAttachments=\(metadata.unavailableAttachmentCount) " +
        "dropReasons=\(metadata.dropReasons) fingerprint=\(metadata.fingerprint)"
}

/// Reads a stable pasteboard snapshot so a queued observation is never classified
/// with marker types belonging to a different change count.
func captureClipboardPasteboardSnapshot(
    from pasteboard: NSPasteboard,
    source: String,
    maximumAttempts: Int = 3,
    includeAttachments: Bool = true,
    captureOriginalSnapshot: Bool = false,
    attachmentLimits: ClipboardAttachmentLimits = .default
) -> ClipboardPasteboardSnapshot? {
    let attemptCount = max(1, maximumAttempts)
    var unstableAttempts: [String] = []
    for attempt in 1...attemptCount {
        let changeCountBeforeRead = pasteboard.changeCount
        let types = pasteboard.types ?? []
        let content = pasteboard.string(forType: .string)
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        var itemRepresentations = pasteboardItems.map {
            readClipboardPasteboardItemRepresentations(
                $0,
                includeAttachments: includeAttachments,
                captureAllImageRepresentations: captureOriginalSnapshot
            )
        }
        itemRepresentations = supplementClipboardImageRepresentations(
            itemRepresentations,
            from: pasteboard,
            legacyText: content,
            includeAttachments: includeAttachments,
            captureAllImageRepresentations: captureOriginalSnapshot
        )
        let unsupportedOnlyItemCount = itemRepresentations.filter { item in
            item.text == nil &&
                !item.hasFileURLRepresentation &&
                !item.hasPNGRepresentation &&
                !item.hasTIFFRepresentation
        }.count
        let unsupportedPasteboardOnlyCount = itemRepresentations.isEmpty &&
            !types.isEmpty && content == nil ? 1 : 0
        let payload = makeClipboardPayload(
            items: itemRepresentations,
            legacyText: content,
            limits: attachmentLimits
        )
        let originalSnapshot = captureOriginalSnapshot
            ? makeClipboardOriginalSnapshot(
                items: itemRepresentations,
                legacyText: content,
                changeCount: changeCountBeforeRead,
                unsupportedRepresentationCount:
                    unsupportedOnlyItemCount + unsupportedPasteboardOnlyCount,
                limits: attachmentLimits
            )
            : nil
        let changeCountAfterRead = pasteboard.changeCount
        if changeCountBeforeRead == changeCountAfterRead {
            if !unstableAttempts.isEmpty {
                logDebug(
                    "[ClipboardMonitor] Clipboard diagnostic source=\(source) snapshot=recovered " +
                    "attempt=\(attempt) priorAttempts=\(unstableAttempts) " +
                    "stableChangeCount=\(changeCountAfterRead) types=\(types.map(\.rawValue).sorted())"
                )
            }
            return ClipboardPasteboardSnapshot(
                changeCount: changeCountAfterRead,
                content: content,
                types: types,
                payload: payload,
                originalSnapshot: originalSnapshot
            )
        }
        unstableAttempts.append(
            "attempt=\(attempt),before=\(changeCountBeforeRead),after=\(changeCountAfterRead)," +
            "types=\(types.map(\.rawValue).sorted())"
        )
    }
    logDebug(
        "[ClipboardMonitor] Clipboard diagnostic source=\(source) snapshot=unstable " +
        "attempts=\(unstableAttempts)"
    )
    return nil
}

private func readClipboardFileURL(from item: NSPasteboardItem) -> URL? {
    if let value = item.propertyList(forType: .fileURL) {
        if let string = value as? String {
            if let url = URL(string: string), url.scheme != nil { return url }
            return URL(fileURLWithPath: string)
        }
        if let data = value as? Data,
           let property = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ),
           let string = property as? String {
            if let url = URL(string: string), url.scheme != nil { return url }
            return URL(fileURLWithPath: string)
        }
    }
    if let string = item.string(forType: .fileURL) {
        if let url = URL(string: string), url.scheme != nil { return url }
        return URL(fileURLWithPath: string)
    }
    return nil
}

private func readClipboardPasteboardItemRepresentations(
    _ item: NSPasteboardItem,
    includeAttachments: Bool,
    captureAllImageRepresentations: Bool
) -> ClipboardPasteboardItemRepresentations {
    let types = Set(item.types)
    let hasFileURL = types.contains(.fileURL)
    let hasPNG = types.contains(.png)
    let hasTIFF = types.contains(.tiff)

    // URL extraction reads only the URL representation. It never opens or
    // stats the referenced file.
    let fileURL = hasFileURL ? readClipboardFileURL(from: item) : nil
    let pngData = includeAttachments && hasPNG ? item.data(forType: .png) : nil
    let shouldReadTIFF = includeAttachments && hasTIFF && (
        captureAllImageRepresentations || pngData == nil
    )
    let tiffData = shouldReadTIFF ? item.data(forType: .tiff) : nil
    let text = item.string(forType: .string)

    return ClipboardPasteboardItemRepresentations(
        text: text,
        fileURL: fileURL,
        pngData: pngData,
        tiffData: tiffData,
        hasFileURLRepresentation: hasFileURL,
        hasPNGRepresentation: hasPNG,
        hasTIFFRepresentation: hasTIFF
    )
}

/// AppKit may vend a supported image conversion on the pasteboard even when
/// its item advertises only a source format (for example Finder's ICNS icons).
/// The board-level representation is attributable only for a single-item copy.
private func supplementClipboardImageRepresentations(
    _ items: [ClipboardPasteboardItemRepresentations],
    from pasteboard: NSPasteboard,
    legacyText: String?,
    includeAttachments: Bool,
    captureAllImageRepresentations: Bool
) -> [ClipboardPasteboardItemRepresentations] {
    guard includeAttachments, items.count <= 1 else { return items }
    let item = items.first ?? ClipboardPasteboardItemRepresentations(text: legacyText)
    let types = Set(pasteboard.types ?? [])
    // A file's image preview must never replace its borrowed file URL. Keep
    // already readable per-item images authoritative as well.
    guard !item.hasFileURLRepresentation, !types.contains(.fileURL),
          item.pngData == nil, item.tiffData == nil else { return items }
    let hasPNG = types.contains(.png)
    let hasTIFF = types.contains(.tiff)
    guard hasPNG || hasTIFF else { return items }
    let pngData = hasPNG ? pasteboard.data(forType: .png) : nil
    let tiffData = hasTIFF && (captureAllImageRepresentations || pngData == nil)
        ? pasteboard.data(forType: .tiff) : nil
    return [ClipboardPasteboardItemRepresentations(
        text: item.text,
        fileURL: item.fileURL,
        pngData: pngData,
        tiffData: tiffData,
        hasFileURLRepresentation: item.hasFileURLRepresentation,
        hasPNGRepresentation: item.hasPNGRepresentation || hasPNG,
        hasTIFFRepresentation: item.hasTIFFRepresentation || hasTIFF
    )]
}

struct SessionClipboardObservationDecision {
    let shouldCaptureInSessionHistory: Bool
    let shouldCountAsRecentActivity: Bool
}

enum ClipboardObservationMergeDecision: Equatable {
    case append
    case keepExisting
    case upgradeMissingContent
}

/// A provider can publish its image after the operation's first empty read,
/// without advancing changeCount. Repair that observation once bytes arrive;
/// deliberate budget eviction and complete payloads must not be rerecorded.
func shouldUpgradeClipboardImageObservation(
    existing: ClipboardPayload,
    incoming: ClipboardPayload
) -> Bool {
    guard incoming.retainedImageByteCount > 0 else { return false }
    guard !existing.items.contains(where: { item in
        if case .unavailableImage(_, _, let reason) = item { return reason != .missingData }
        return false
    }) else { return false }
    let wasUnready = existing.kind == .empty || existing.items.contains { item in
        if case .unavailableImage(_, _, .missingData) = item { return true }
        return false
    }
    return wasUnready && clipboardObservationMergeDecision(
        hasExistingObservation: true,
        existingPayload: existing,
        incomingPayload: incoming
    ) == .upgradeMissingContent
}

func clipboardObservationMergeDecision(
    hasExistingObservation: Bool,
    existingPayload: ClipboardPayload?,
    incomingPayload: ClipboardPayload?
) -> ClipboardObservationMergeDecision {
    guard hasExistingObservation else { return .append }
    guard let existingPayload else {
        return incomingPayload == nil ? .keepExisting : .upgradeMissingContent
    }
    guard let incomingPayload else { return .keepExisting }
    if existingPayload.fingerprint == incomingPayload.fingerprint {
        return .keepExisting
    }
    // A later sampler may fill in an image/file payload that the first sampler
    // could not resolve. Do not overwrite a complete representation with a
    // different same-count observation.
    if existingPayload.kind == .empty ||
        (!existingPayload.hasAttachments && incomingPayload.hasAttachments &&
         existingPayload.legacyText == incomingPayload.legacyText) ||
        (existingPayload.unavailableAttachmentCount > 0 && incomingPayload.unavailableAttachmentCount == 0) ||
        (existingPayload.items.isEmpty && !incomingPayload.items.isEmpty) {
        return .upgradeMissingContent
    }
    return .keepExisting
}

/// Reconciles multiple samples of the same pasteboard operation.
///
/// A pasteboard provider can increment `changeCount` before its string payload is
/// available. If another monitor resolves the payload moments later, that more
/// complete sample should repair the existing observation without creating a
/// second clipboard event. Separate user copy operations still have different
/// change counts and therefore continue to be captured independently.
func clipboardObservationMergeDecision(
    hasExistingObservation: Bool,
    existingContent: String?,
    incomingContent: String?
) -> ClipboardObservationMergeDecision {
    guard hasExistingObservation else { return .append }
    if existingContent == nil, incomingContent != nil {
        return .upgradeMissingContent
    }
    return .keepExisting
}

struct ClipboardContextRepresentations: Equatable {
    let single: String
    let stacked: String

    func value(enableStacking: Bool) -> String {
        enableStacking ? stacked : single
    }
}

enum ExecutionGroupJoinDecision: Equatable {
    case executingAction
    case pendingRestore
    case noActiveOperation
    case stale

    var shouldJoin: Bool {
        switch self {
        case .executingAction, .pendingRestore:
            return true
        case .noActiveOperation, .stale:
            return false
        }
    }
}

func executionGroupJoinDecision(
    age: TimeInterval,
    hasExecutingAction: Bool,
    hasPendingRestore: Bool,
    maximumAge: TimeInterval = MAX_EXECUTION_GROUP_JOIN_AGE
) -> ExecutionGroupJoinDecision {
    guard age <= max(0, maximumAge) else {
        return .stale
    }
    if hasExecutingAction {
        return .executingAction
    }
    if hasPendingRestore {
        return .pendingRestore
    }
    return .noActiveOperation
}

struct ClipboardRecoveryAbortSummary {
    let groupCount: Int
    let sessionCount: Int
    let clipboardChangeCount: Int
    let preRecordingItemCount: Int
}

func makeClipboardContextRepresentations(
    candidates: [String],
    swResult: String,
    maxSwResultCompareChars: Int = 16_384
) -> ClipboardContextRepresentations {
    let normalizedSwResult = sanitizeContextPlaceholderValue(swResult)
    let filteredCandidates = candidates.compactMap { candidate -> String? in
        let normalized = sanitizeContextPlaceholderValue(candidate)
        guard !normalized.isEmpty else { return nil }

        let matchesSuperwhisperResult = clipboardTextMatchesSuperwhisperResult(
            normalized,
            swResult: normalizedSwResult,
            maxCompareChars: maxSwResultCompareChars
        )
        return matchesSuperwhisperResult ? nil : normalized
    }

    let single = filteredCandidates.last ?? ""
    guard filteredCandidates.count > 1 else {
        return ClipboardContextRepresentations(single: single, stacked: single)
    }

    let stacked = filteredCandidates.enumerated().map { index, content in
        let tagNumber = index + 1
        return "<clipboard-context-\(tagNumber)>\n\(content)\n</clipboard-context-\(tagNumber)>"
    }.joined(separator: "\n\n")

    return ClipboardContextRepresentations(single: single, stacked: stacked)
}

/// Compares a clipboard projection with the recording result using only the
/// formatting changes Superwhisper commonly applies while publishing its result.
/// This deliberately stays narrower than general natural-language normalization.
func clipboardTextMatchesSuperwhisperResult(
    _ clipboardText: String,
    swResult: String,
    maxCompareChars: Int = 16_384
) -> Bool {
    let normalizedClipboard = sanitizeContextPlaceholderValue(clipboardText)
    let normalizedResult = sanitizeContextPlaceholderValue(swResult)
    guard !normalizedClipboard.isEmpty,
          !normalizedResult.isEmpty,
          normalizedClipboard.count <= maxCompareChars,
          normalizedResult.count <= maxCompareChars else {
        return false
    }
    if normalizedClipboard == normalizedResult {
        return true
    }

    let comparisonLocale = Locale(identifier: "en_US_POSIX")
    let foldedClipboard = normalizedClipboard.folding(
        options: [.caseInsensitive],
        locale: comparisonLocale
    )
    let foldedResult = normalizedResult.folding(
        options: [.caseInsensitive],
        locale: comparisonLocale
    )
    if foldedClipboard == foldedResult {
        return true
    }

    let terminalFormatting = CharacterSet(charactersIn: ".!?\u{2026}\u{3002}\u{FF01}\u{FF1F}")
        .union(.whitespacesAndNewlines)
    let trimmedClipboard = foldedClipboard.trimmingCharacters(in: terminalFormatting)
    let trimmedResult = foldedResult.trimmingCharacters(in: terminalFormatting)
    return !trimmedClipboard.isEmpty && trimmedClipboard == trimmedResult
}

/// Projects one ordered clipboard-operation stream into the string placeholder
/// views and attachment handoff candidates. When attachments are disabled,
/// attachment-classified operations deliberately use their legacy text view.
func makeClipboardOperationContextSnapshot(
    orderedPayloads: [ClipboardPayload],
    fallbackTextCandidates: [String],
    swResult: String,
    attachmentsEnabled: Bool,
    maxSwResultCompareChars: Int = 16_384
) -> ClipboardContextSnapshot {
    let baseRepresentations = makeClipboardContextRepresentations(
        candidates: fallbackTextCandidates,
        swResult: swResult,
        maxSwResultCompareChars: maxSwResultCompareChars
    )
    let eligiblePayloads = orderedPayloads.filter { payload in
        if attachmentsEnabled && payload.hasAttachments { return true }
        guard let text = payload.textProjection(attachmentsEnabled: attachmentsEnabled) else {
            return false
        }
        let normalized = sanitizeContextPlaceholderValue(text)
        guard !normalized.isEmpty else { return false }
        return !clipboardTextMatchesSuperwhisperResult(
            normalized,
            swResult: swResult,
            maxCompareChars: maxSwResultCompareChars
        )
    }
    let eligibleTextCandidates = eligiblePayloads.compactMap { payload -> String? in
        guard !(attachmentsEnabled && payload.hasAttachments),
              let text = payload.textProjection(attachmentsEnabled: attachmentsEnabled) else {
            return nil
        }
        let normalized = sanitizeContextPlaceholderValue(text)
        return normalized.isEmpty ? nil : normalized
    }
    let containsEnabledAttachment = attachmentsEnabled && orderedPayloads.contains(where: \.hasAttachments)
    let projectedTextCandidates = eligibleTextCandidates.isEmpty && !containsEnabledAttachment
        ? fallbackTextCandidates
        : eligibleTextCandidates
    let textRepresentations = makeClipboardContextRepresentations(
        candidates: projectedTextCandidates,
        swResult: swResult,
        maxSwResultCompareChars: maxSwResultCompareChars
    )

    let single: String
    if let latest = eligiblePayloads.last {
        single = attachmentsEnabled && latest.hasAttachments
            ? ""
            : textRepresentations.single
    } else if attachmentsEnabled && orderedPayloads.last?.hasAttachments == true {
        single = ""
    } else {
        single = baseRepresentations.single
    }

    return ClipboardContextSnapshot(
        representations: ClipboardContextRepresentations(
            single: single,
            stacked: textRepresentations.stacked
        ),
        orderedPayloads: orderedPayloads,
        attachmentCandidates: orderedPayloads.filter(\.hasAttachments)
    )
}

enum ClipboardContextResetScope {
    case activeSession(recordingPath: String)
    case preRecordingBuffer
}

func shouldIncludeClipboardChange(
    timestamp: Date,
    resetAt: Date?
) -> Bool {
    guard let resetAt else { return true }
    return timestamp >= resetAt
}

enum SessionStartInputFieldState: String {
    case inInputField
    case outsideInputField
    case unknown

    var logValue: String {
        switch self {
        case .inInputField:
            return "in-input-field"
        case .outsideInputField:
            return "outside-input-field"
        case .unknown:
            return "unknown"
        }
    }
}

func shouldAllowAdjacentStartupTransientCandidate(
    sessionStartInputFieldState: SessionStartInputFieldState,
    sessionStartTime: Date,
    startupReplayGuardEndsAt: Date?,
    startingChangeCount: Int,
    changeCount: Int,
    observedAt: Date,
    candidateWindow: TimeInterval = ADJACENT_STARTUP_TRANSIENT_CANDIDATE_WINDOW
) -> Bool {
    guard sessionStartInputFieldState == .outsideInputField,
          let startupReplayGuardEndsAt,
          observedAt >= sessionStartTime,
          observedAt <= startupReplayGuardEndsAt,
          observedAt <= sessionStartTime.addingTimeInterval(max(0, candidateWindow)) else {
        return false
    }

    let expectedChangeCount = startingChangeCount.addingReportingOverflow(1)
    return !expectedChangeCount.overflow && changeCount == expectedChangeCount.partialValue
}

enum SessionStartClipboardReplayDecision: String {
    case ignoredStartupReplay = "ignored-startup-replay"
    case ignoredKnownChangeCount = "ignored-known-change-count"
    case capturedGuardEnded = "captured-guard-ended"
    case capturedBeforeWindow = "captured-before-startup-window"
    case capturedAfterWindow = "captured-after-startup-window"
    case capturedDifferentContent = "captured-different-content"
}

struct SessionStartClipboardReplayEvaluation {
    let shouldIgnore: Bool
    let matchesPreviousClipboard: Bool
    let millisecondsFromSessionStart: Int
    let decision: SessionStartClipboardReplayDecision
}

func isSameContentClipboardRewrite(
    currentClipboard: String?,
    previousClipboard: String?
) -> Bool {
    guard let currentClipboard, let previousClipboard else { return false }
    return currentClipboard == previousClipboard
}

func isSameClipboardPayloadRewrite(
    currentPayload: ClipboardPayload?,
    previousPayload: ClipboardPayload?
) -> Bool {
    guard let currentPayload, let previousPayload else { return false }
    return currentPayload.fingerprint == previousPayload.fingerprint
}

func evaluateSessionStartClipboardReplay(
    isSameContentRewrite: Bool,
    sessionStartTime: Date,
    guardEndsAt: Date?,
    observedAt: Date,
    lookback: TimeInterval = 3.0
) -> SessionStartClipboardReplayEvaluation {
    let millisecondsFromSessionStart = Int(
        (observedAt.timeIntervalSince(sessionStartTime) * 1_000).rounded()
    )

    guard let guardEndsAt else {
        return SessionStartClipboardReplayEvaluation(
            shouldIgnore: false,
            matchesPreviousClipboard: isSameContentRewrite,
            millisecondsFromSessionStart: millisecondsFromSessionStart,
            decision: .capturedGuardEnded
        )
    }

    if observedAt < sessionStartTime.addingTimeInterval(-max(0, lookback)) {
        return SessionStartClipboardReplayEvaluation(
            shouldIgnore: false,
            matchesPreviousClipboard: isSameContentRewrite,
            millisecondsFromSessionStart: millisecondsFromSessionStart,
            decision: .capturedBeforeWindow
        )
    }

    if observedAt > guardEndsAt {
        return SessionStartClipboardReplayEvaluation(
            shouldIgnore: false,
            matchesPreviousClipboard: isSameContentRewrite,
            millisecondsFromSessionStart: millisecondsFromSessionStart,
            decision: .capturedAfterWindow
        )
    }

    guard isSameContentRewrite else {
        return SessionStartClipboardReplayEvaluation(
            shouldIgnore: false,
            matchesPreviousClipboard: false,
            millisecondsFromSessionStart: millisecondsFromSessionStart,
            decision: .capturedDifferentContent
        )
    }

    return SessionStartClipboardReplayEvaluation(
        shouldIgnore: true,
        matchesPreviousClipboard: true,
        millisecondsFromSessionStart: millisecondsFromSessionStart,
        decision: .ignoredStartupReplay
    )
}

func decideSessionClipboardObservation(
    shouldIgnoreApp: Bool,
    containsIgnoredMarker: Bool
) -> SessionClipboardObservationDecision {
    if containsIgnoredMarker {
        return SessionClipboardObservationDecision(
            shouldCaptureInSessionHistory: false,
            shouldCountAsRecentActivity: true
        )
    }

    if shouldIgnoreApp {
        return SessionClipboardObservationDecision(
            shouldCaptureInSessionHistory: false,
            shouldCountAsRecentActivity: false
        )
    }

    return SessionClipboardObservationDecision(
        shouldCaptureInSessionHistory: true,
        shouldCountAsRecentActivity: true
    )
}

/// Handles clipboard monitoring and synchronization for action execution triggered by valid results
/// This solves timing issues where Superwhisper and Macrowhisper can modify clipboard around the same time.
class ClipboardMonitor {
    private let logger: Logger
    private let attachmentLimits: ClipboardAttachmentLimits
    private let attachmentFileStore: ClipboardAttachmentFileStore
    private var clipboardAttachmentsEnabled: Bool
    private let maxWaitTime: TimeInterval = 0.1 // Maximum time to wait for Superwhisper's clipboard change
    private let pollInterval: TimeInterval = 0.01 // 10ms polling interval
    private let recentClipboardActivityWindow: TimeInterval = 0.5 // Treat very recent session clipboard activity as Superwhisper sync
    private let maxSwResultCompareChars: Int = 16_384
    
    // Global clipboard history for pre-recording capture (lightweight, app-lifetime monitoring)
    private var preRecordingBuffer: TimeInterval // Keep N seconds of history (0 disables)
    
    // Clipboard ignore pattern for filtering clipboard content from specific apps
    private var clipboardIgnorePattern: String
    
    /// Dynamic cleanup interval that scales with user's clipboard buffer setting
    private var cleanupInterval: TimeInterval {
        return max(30.0, preRecordingBuffer + 10.0)
    }
    
    private var globalClipboardHistory: [ClipboardChange] = []
    private let globalHistoryQueue = DispatchQueue(label: "ClipboardMonitor.globalHistory", attributes: .concurrent)
    private let cliSuppressionQueue = DispatchQueue(label: "ClipboardMonitor.cliSuppression")
    private let ignoredMarkerSequenceQueue = DispatchQueue(label: "ClipboardMonitor.ignoredMarkerSequence")
    private var ignoredMarkerSequenceTracker = IgnoredClipboardMarkerSequenceTracker()
    private var inferredTransientRestoreTracker = InferredTransientRestoreTracker()
    private var globalMonitoringTimer: Timer?
    private var isFirstGlobalCheck = true // Track if this is the first clipboard check
    private var lastSeenClipboardContent: String? // Track last seen content independently of history
    private var lastSeenClipboardPayload: ClipboardPayload?
    private var lastSeenChangeCount: Int = 0 // Track NSPasteboard changeCount for more reliable detection
    private var lastSeenClipboardChangeObservedAt: Date? // Diagnostic timing for the previous global change
    private var clipboardContextResetAt: Date? = nil
    private var suppressedCliClipboardContent: String?
    private var suppressedCliClipboardFingerprint: String?
    private var suppressedCliClipboardUntil: Date = .distantPast
    
    // Early monitoring state for recording sessions - made thread-safe with bounds management
    private var earlyMonitoringSessions: [String: EarlyMonitoringSession] = [:]
    private let sessionsQueue = DispatchQueue(label: "ClipboardMonitor.sessions", attributes: .concurrent)
    private var cleanupTimer: Timer? // Periodic cleanup timer to prevent memory growth
    private var executionGroups: [String: ExecutionGroup] = [:]
    private var recordingPathToGroupId: [String: String] = [:]

    private func logNoContentIfNeeded(_ key: String, _ message: String) {
        if shouldEmitRateLimitedLog(key: "ClipboardMonitor.\(key)", cooldown: 3.0) {
            logDebug(message)
        }
    }

    private func logClipboardObservationDiagnostic(
        source: String,
        snapshot: ClipboardPasteboardSnapshot,
        observedAt: Date,
        previousChangeCount: Int?,
        previousObservedAt: Date?,
        previousContent: String?
    ) {
        let metadata = makeClipboardObservationDiagnosticMetadata(
            changeCount: snapshot.changeCount,
            previousChangeCount: previousChangeCount,
            observedAt: observedAt,
            previousObservedAt: previousObservedAt,
            content: snapshot.content,
            previousContent: previousContent,
            pasteboardTypes: snapshot.types.map(\.rawValue)
        )
        logDebug(clipboardObservationDiagnosticLogMessage(source: source, metadata: metadata))
        let payloadMetadata = makeClipboardPayloadDiagnosticMetadata(snapshot.payload)
        logDebug(clipboardPayloadDiagnosticLogMessage(source: source, metadata: payloadMetadata))
    }
    
    private struct EarlyMonitoringSession {
        let groupId: String
        let startTime: Date
        var clipboardChanges: [ClipboardChange] = []
        var isActive: Bool = true
        let selectedText: String?  // Capture selected text at session start
        let sessionStartInputFieldState: SessionStartInputFieldState
        var isExecutingAction: Bool = false  // Only log clipboard changes during action execution
        var preRecordingClipboard: String?  // Clipboard content captured from global history before recording (mutable for cleanup)
        var preRecordingClipboardStack: [String]  // All clipboard content captured from global history before recording (mutable for cleanup)
        var preRecordingChanges: [ClipboardChange]  // Preserve full observations for retroactive startup filtering
        var preRecordingIgnoredReplayCount: Int
        var startupReplayGuardEndsAt: Date?
        let startingChangeCount: Int  // NSPasteboard changeCount at session start for better tracking
        var lastSeenChangeCount: Int  // Track last seen changeCount for this session
        var hasAudioRecordingStarted: Bool = false
        var lastCapturedClipboardContent: String? // The last unique clipboard content captured during early monitoring
        var lastCapturedClipboardPayload: ClipboardPayload?
        var startupBootstrapState: StartupClipboardBootstrapState?
        var ignoredClipboardChangeCounts: Set<Int> = []
        var lastObservedClipboardActivityAt: Date? = nil
        var lastDiagnosticClipboardChangeObservedAt: Date? = nil
        var clipboardContextResetAt: Date? = nil
        var frozenContextSnapshot: ClipboardContextSnapshot? = nil
    }

    private struct ExecutionGroup {
        let id: String
        let createdAt: Date
        let rootRecordingPath: String
        var rootOriginalSnapshot: ClipboardOriginalSnapshot?
        var rootClipboardAttachmentsEnabled: Bool
        var rootClipboardStackingEnabled: Bool
        let rootSelectedText: String?
        let rootSessionStartInputFieldState: SessionStartInputFieldState
        var rootPreRecordingClipboard: String?
        var rootPreRecordingClipboardStack: [String]
        var rootPreRecordingChanges: [ClipboardChange]
        var rootPreRecordingIgnoredReplayCount: Int
        var clipboardContextResetAt: Date?
        var memberRecordingPaths: Set<String>
        var pendingRestoreRecordingPath: String?
        var pendingRestoreDelay: TimeInterval
        var pendingCleanupDelay: TimeInterval
        var scriptResults: [String]
        var attachmentHandoffPolicy: ClipboardAttachmentHandoffPolicy = .disabled
        var frozenContextSnapshot: ClipboardContextSnapshot?
        var pendingFinalizationRecordingPath: String? = nil
        var pendingFinalizationDelay: TimeInterval = DEFAULT_CLIPBOARD_RESTORE_DELAY
        let finalizationToken: String
    }
    
    private struct ClipboardChange {
        let content: String?
        var payload: ClipboardPayload
        let timestamp: Date
        let changeCount: Int  // NSPasteboard changeCount when this change was detected
        let frontAppName: String?  // Name of the frontmost app that made this change
        let frontAppBundleId: String?  // Bundle ID of the frontmost app that made this change
        let pasteboardTypes: [String]
        let isSameContentRewrite: Bool

        init(
            content: String?,
            payload: ClipboardPayload? = nil,
            timestamp: Date,
            changeCount: Int,
            frontAppName: String?,
            frontAppBundleId: String?,
            pasteboardTypes: [String],
            isSameContentRewrite: Bool
        ) {
            self.content = content
            self.payload = payload ?? ClipboardPayload(
                items: content.map { [.text($0)] } ?? [],
                legacyText: content
            )
            self.timestamp = timestamp
            self.changeCount = changeCount
            self.frontAppName = frontAppName
            self.frontAppBundleId = frontAppBundleId
            self.pasteboardTypes = pasteboardTypes
            self.isSameContentRewrite = isSameContentRewrite
        }
    }

    @discardableResult
    private func mergeClipboardChange(
        _ incoming: ClipboardChange,
        into session: inout EarlyMonitoringSession
    ) -> ClipboardObservationMergeDecision {
        let existingIndex = session.clipboardChanges.firstIndex {
            $0.changeCount == incoming.changeCount
        }
        let existing = existingIndex.map { session.clipboardChanges[$0] }
        let decision = clipboardObservationMergeDecision(
            hasExistingObservation: existing != nil,
            existingPayload: existing?.payload,
            incomingPayload: incoming.payload
        )

        switch decision {
        case .append:
            session.clipboardChanges.append(incoming)
            if session.clipboardChanges.count > MAX_SESSION_CLIPBOARD_CHANGES {
                let excessCount = session.clipboardChanges.count - MAX_SESSION_CLIPBOARD_CHANGES
                session.clipboardChanges.removeFirst(excessCount)
                logDebug("[ClipboardMonitor] Trimmed \(excessCount) old clipboard changes to stay within bounds")
            }

        case .upgradeMissingContent:
            guard let existingIndex, let existing else { break }
            session.clipboardChanges[existingIndex] = ClipboardChange(
                content: incoming.content,
                payload: incoming.payload,
                timestamp: existing.timestamp,
                changeCount: existing.changeCount,
                frontAppName: existing.frontAppName ?? incoming.frontAppName,
                frontAppBundleId: existing.frontAppBundleId ?? incoming.frontAppBundleId,
                pasteboardTypes: existing.pasteboardTypes.isEmpty ? incoming.pasteboardTypes : existing.pasteboardTypes,
                isSameContentRewrite: incoming.isSameContentRewrite
            )

        case .keepExisting:
            break
        }

        session.lastSeenChangeCount = incoming.changeCount
        session.lastObservedClipboardActivityAt = incoming.timestamp
        if let incomingContent = incoming.content {
            session.lastCapturedClipboardContent = incomingContent
        }
        session.lastCapturedClipboardPayload = incoming.payload
        return decision
    }

    private func upgradedClipboardImageChange(
        _ existing: ClipboardChange,
        snapshot: ClipboardPasteboardSnapshot
    ) -> ClipboardChange? {
        guard existing.changeCount == snapshot.changeCount,
              shouldUpgradeClipboardImageObservation(existing: existing.payload, incoming: snapshot.payload) else {
            return nil
        }
        return ClipboardChange(
            content: snapshot.payload.textProjection(attachmentsEnabled: true),
            payload: snapshot.payload,
            timestamp: existing.timestamp,
            changeCount: existing.changeCount,
            frontAppName: existing.frontAppName,
            frontAppBundleId: existing.frontAppBundleId,
            pasteboardTypes: snapshot.types.isEmpty ? existing.pasteboardTypes : snapshot.types.map(\.rawValue).sorted(),
            isSameContentRewrite: existing.isSameContentRewrite
        )
    }
    
    init(
        logger: Logger,
        preRecordingBufferSeconds: TimeInterval = 5.0,
        clipboardIgnore: String = "",
        clipboardAttachments: Bool = false,
        attachmentLimits: ClipboardAttachmentLimits = .default,
        attachmentFileStore: ClipboardAttachmentFileStore = ClipboardAttachmentFileStore()
    ) {
        self.logger = logger
        self.clipboardAttachmentsEnabled = clipboardAttachments
        self.attachmentLimits = attachmentLimits
        self.attachmentFileStore = attachmentFileStore
        self.preRecordingBuffer = max(0.0, preRecordingBufferSeconds)
        self.clipboardIgnorePattern = clipboardIgnore
        // Initialize with current pasteboard state
        let pasteboard = NSPasteboard.general
        lastSeenChangeCount = pasteboard.changeCount
        let removedAttachmentGenerationCount = attachmentFileStore.cleanupUnused(pasteboard: pasteboard)
        if removedAttachmentGenerationCount > 0 {
            logDebug(
                "[ClipboardMonitor] Removed \(removedAttachmentGenerationCount) unreferenced generated attachment " +
                "generation(s) during startup cleanup"
            )
        }
        if self.preRecordingBuffer > 0 {
            startGlobalClipboardMonitoring()
        } else {
            logDebug("[ClipboardMonitor] Global clipboard buffer disabled (clipboardBuffer = 0)")
        }
        
        // Start periodic cleanup to prevent memory growth
        startPeriodicCleanup()
    }
    
    deinit {
        stopGlobalClipboardMonitoring()
        stopPeriodicCleanup()
    }

    /// Returns the portion of the aggregate image budget still available for
    /// a newly protected original snapshot. Existing originals and frozen
    /// context snapshots cannot be evicted without changing restoration or
    /// handoff semantics, so a new capture is classified as unavailable when
    /// no protected budget remains.
    private func limitsForNewOriginalSnapshot(
        replacingOriginalForGroupId: String? = nil
    ) -> ClipboardAttachmentLimits {
        var protectedBytes = 0
        sessionsQueue.sync {
            protectedBytes += executionGroups.reduce(0) { total, entry in
                guard entry.key != replacingOriginalForGroupId else { return total }
                return total + (entry.value.rootOriginalSnapshot?.retainedImageByteCount ?? 0)
            }
            protectedBytes += executionGroups.reduce(0) {
                $0 + ($1.value.frozenContextSnapshot?.retainedImageByteCount ?? 0)
            }
        }
        let remaining = max(0, attachmentLimits.aggregateImageBytes - protectedBytes)
        return ClipboardAttachmentLimits(
            perImageBytes: attachmentLimits.perImageBytes,
            aggregateImageBytes: remaining
        )
    }

    /// Bounds a context snapshot against image data already protected for
    /// restoration or another execution group's frozen handoff. Text and
    /// attachment classification survive eviction; only retained image bytes
    /// are released.
    private func boundedFrozenContextSnapshot(
        _ snapshot: ClipboardContextSnapshot,
        for recordingPath: String
    ) -> ClipboardContextSnapshot {
        var result = snapshot
        var droppedImageCount = 0
        var retainedImageBytes = snapshot.retainedImageByteCount
        var availableBytes = attachmentLimits.aggregateImageBytes
        sessionsQueue.sync(flags: .barrier) {
            let currentGroupId = recordingPathToGroupId[recordingPath]
            var protectedBytes = executionGroups.values.reduce(0) {
                $0 + ($1.rootOriginalSnapshot?.retainedImageByteCount ?? 0)
            }
            protectedBytes += executionGroups.reduce(0) { total, entry in
                guard entry.key != currentGroupId else { return total }
                return total + (entry.value.frozenContextSnapshot?.retainedImageByteCount ?? 0)
            }
            availableBytes = max(0, attachmentLimits.aggregateImageBytes - protectedBytes)
            let bounded = applyClipboardImageRetentionBudget(
                to: snapshot.orderedPayloads,
                limits: ClipboardAttachmentLimits(
                    perImageBytes: attachmentLimits.perImageBytes,
                    aggregateImageBytes: availableBytes
                )
            )
            droppedImageCount = bounded.droppedImageCount
            retainedImageBytes = bounded.retainedImageBytes
            if droppedImageCount > 0 {
                let payloads = bounded.payloads
                result = ClipboardContextSnapshot(
                    representations: snapshot.representations,
                    orderedPayloads: payloads,
                    attachmentCandidates: payloads.filter(\.hasAttachments)
                )
            }

            if var session = earlyMonitoringSessions[recordingPath] {
                session.frozenContextSnapshot = result
                earlyMonitoringSessions[recordingPath] = session
            }
            if let groupId = currentGroupId, var group = executionGroups[groupId] {
                group.frozenContextSnapshot = result
                executionGroups[groupId] = group
            }
        }
        if droppedImageCount > 0 {
            logDebug(
                "[ClipboardMonitor] Bounded frozen attachment context " +
                "(reason: aggregate-limit, droppedItems: \(droppedImageCount), " +
                "retainedImageBytes: \(retainedImageBytes), availableBytes: \(availableBytes))"
            )
        }
        return result
    }
    
    /// Starts early clipboard monitoring when a recording folder appears
    /// This captures the user's original clipboard before anyone (Superwhisper or CLI) modifies it
    /// Also captures selected text at the moment the recording folder appears
    /// Enhanced to also capture clipboard content from approximately 5 seconds before recording
    func startEarlyMonitoring(for recordingPath: String, sessionStartTime: Date = Date()) {
        var stableGlobalChangeCount: Int?
        var stableGlobalPayloadFingerprint: String?
        var stableGlobalContent: String?
        var stableGlobalObservedAt: Date?
        globalHistoryQueue.sync {
            guard !isFirstGlobalCheck, let lastSeenClipboardPayload else { return }
            stableGlobalChangeCount = lastSeenChangeCount
            stableGlobalPayloadFingerprint = lastSeenClipboardPayload.fingerprint
            stableGlobalContent = lastSeenClipboardContent
            stableGlobalObservedAt = lastSeenClipboardChangeObservedAt
        }

        let pasteboard = NSPasteboard.general
        let originalCaptureLimits = limitsForNewOriginalSnapshot()
        let originalPasteboardSnapshot = captureClipboardPasteboardSnapshot(
            from: pasteboard,
            source: "session-start",
            includeAttachments: true,
            captureOriginalSnapshot: true,
            attachmentLimits: originalCaptureLimits
        )
        let sessionSnapshotObservedAt = Date()
        let userOriginalSnapshot = originalPasteboardSnapshot?.originalSnapshot
        let startupBootstrapState: StartupClipboardBootstrapState? = {
            guard let stableGlobalChangeCount,
                  let stableGlobalPayloadFingerprint,
                  let originalPasteboardSnapshot else {
                return nil
            }
            let expectedSessionCount = stableGlobalChangeCount.addingReportingOverflow(1)
            guard !expectedSessionCount.overflow,
                  originalPasteboardSnapshot.changeCount == expectedSessionCount.partialValue,
                  originalPasteboardSnapshot.payload.fingerprint != stableGlobalPayloadFingerprint else {
                return nil
            }
            return StartupClipboardBootstrapState(
                stableGlobalChangeCount: stableGlobalChangeCount,
                stableGlobalPayloadFingerprint: stableGlobalPayloadFingerprint,
                stableGlobalLastChangeObservedAt: stableGlobalObservedAt,
                sessionSnapshotChangeCount: originalPasteboardSnapshot.changeCount,
                sessionSnapshotPayloadFingerprint: originalPasteboardSnapshot.payload.fingerprint,
                sessionSnapshotObservedAt: sessionSnapshotObservedAt
            )
        }()
        if startupBootstrapState != nil, let originalPasteboardSnapshot {
            logClipboardObservationDiagnostic(
                source: "session-start-bootstrap",
                snapshot: originalPasteboardSnapshot,
                observedAt: sessionSnapshotObservedAt,
                previousChangeCount: stableGlobalChangeCount,
                previousObservedAt: stableGlobalObservedAt,
                previousContent: stableGlobalContent
            )
        }

        if let payload = originalPasteboardSnapshot?.payload,
           payload.unavailableAttachmentCount > 0 {
            logDebug(
                "[ClipboardMonitor] Original clipboard attachment retention was bounded " +
                "(source: session-start, unavailableAttachments: \(payload.unavailableAttachmentCount), " +
                "dropReasons: \(makeClipboardPayloadDiagnosticMetadata(payload).dropReasons), " +
                "retainedImageBytes: \(payload.retainedImageByteCount))"
            )
        }
        
        // Capture selected text immediately when recording folder appears
        let selectedText = getSelectedText()
        let sessionStartInputFieldState: SessionStartInputFieldState
        if checkAccessibilityPermission() {
            sessionStartInputFieldState = isInInputField() ? .inInputField : .outsideInputField
        } else {
            sessionStartInputFieldState = .unknown
        }
        
        // Preserve complete pre-recording observations so startup replays can be
        // classified retroactively even when they precede recording-folder detection.
        let startupReplayGuardEndsAt = sessionStartTime.addingTimeInterval(STARTUP_CLIPBOARD_REPLAY_FORWARD_WINDOW)
        let preRecordingChanges = capturePreRecordingClipboardChanges(beforeTime: sessionStartTime)
        let ignoredPreRecordingReplayCounts = Set(preRecordingChanges.compactMap { change -> Int? in
            let evaluation = evaluateSessionStartClipboardReplay(
                isSameContentRewrite: change.isSameContentRewrite,
                sessionStartTime: sessionStartTime,
                guardEndsAt: startupReplayGuardEndsAt,
                observedAt: change.timestamp,
                lookback: STARTUP_CLIPBOARD_REPLAY_LOOKBACK
            )
            return evaluation.shouldIgnore ? change.changeCount : nil
        })
        let eligiblePreRecordingChanges = preRecordingChanges.filter {
            !ignoredPreRecordingReplayCounts.contains($0.changeCount)
        }
        let preRecordingClipboardStack = eligiblePreRecordingChanges.compactMap { change -> String? in
            guard let content = change.content else { return nil }
            let normalized = sanitizeContextPlaceholderValue(content)
            return normalized.isEmpty ? nil : normalized
        }
        let preRecordingClipboard = preRecordingClipboardStack.last

        if !ignoredPreRecordingReplayCounts.isEmpty {
            logDebug(
                "[ClipboardMonitor] Retroactively ignored \(ignoredPreRecordingReplayCounts.count) " +
                "same-content startup replay(s) from the \(Int(STARTUP_CLIPBOARD_REPLAY_LOOKBACK))s pre-folder window"
            )
        }
        
        let currentChangeCount = originalPasteboardSnapshot?.changeCount ?? pasteboard.changeCount
        sessionsQueue.sync(flags: .barrier) { [weak self] in
            guard let self else { return }

            let now = Date()
            let staleGroupIds = self.executionGroups.values.compactMap { group -> String? in
                let age = now.timeIntervalSince(group.createdAt)
                return age > MAX_EXECUTION_GROUP_JOIN_AGE ? group.id : nil
            }
            for staleGroupId in staleGroupIds {
                guard let staleGroup = self.executionGroups[staleGroupId] else { continue }
                let stalePaths = Set(self.recordingPathToGroupId.compactMap { path, groupId in
                    groupId == staleGroupId ? path : nil
                }).union(
                    self.earlyMonitoringSessions.compactMap { path, session in
                        session.groupId == staleGroupId ? path : nil
                    }
                )
                let staleClipboardChangeCount = stalePaths.reduce(into: 0) { count, path in
                    count += self.earlyMonitoringSessions[path]?.clipboardChanges.count ?? 0
                }
                for path in stalePaths {
                    self.earlyMonitoringSessions.removeValue(forKey: path)
                    self.recordingPathToGroupId.removeValue(forKey: path)
                }
                self.executionGroups.removeValue(forKey: staleGroupId)
                let ageMilliseconds = Int(max(0, now.timeIntervalSince(staleGroup.createdAt)) * 1_000)
                logWarning(
                    "[ClipboardMonitor] Discarded stale execution group \(staleGroupId) before starting " +
                    "\(recordingPath) (age: \(ageMilliseconds)ms, sessions: \(stalePaths.count), " +
                    "clipboard changes: \(staleClipboardChangeCount)); pending restores were invalidated"
                )
            }

            let joinableGroups = self.executionGroups.values.compactMap { group -> (ExecutionGroup, ExecutionGroupJoinDecision)? in
                let hasExecutingAction = group.memberRecordingPaths.contains { path in
                    self.earlyMonitoringSessions[path]?.isExecutingAction == true
                }
                let decision = executionGroupJoinDecision(
                    age: now.timeIntervalSince(group.createdAt),
                    hasExecutingAction: hasExecutingAction,
                    hasPendingRestore: group.pendingRestoreRecordingPath != nil || group.pendingFinalizationRecordingPath != nil
                )
                return decision.shouldJoin ? (group, decision) : nil
            }
            let activeGroupId = joinableGroups
                .max { lhs, rhs in
                    let lhsStart = lhs.0.createdAt
                    let rhsStart = rhs.0.createdAt
                    if lhsStart != rhsStart {
                        return lhsStart < rhsStart
                    }
                    return lhs.0.id < rhs.0.id
                }?
                .0.id

            if activeGroupId == nil, !self.executionGroups.isEmpty {
                let excluded = self.executionGroups.values.map { group -> String in
                    let hasExecutingAction = group.memberRecordingPaths.contains { path in
                        self.earlyMonitoringSessions[path]?.isExecutingAction == true
                    }
                    let decision = executionGroupJoinDecision(
                        age: now.timeIntervalSince(group.createdAt),
                        hasExecutingAction: hasExecutingAction,
                        hasPendingRestore: group.pendingRestoreRecordingPath != nil || group.pendingFinalizationRecordingPath != nil
                    )
                    let ageMilliseconds = Int(max(0, now.timeIntervalSince(group.createdAt)) * 1_000)
                    return "\(group.id):\(decision):\(ageMilliseconds)ms"
                }.joined(separator: ", ")
                logDebug("[ClipboardMonitor] Starting a fresh execution group; existing groups are not joinable (\(excluded))")
            }

            let groupId: String
            let effectiveLastCapturedClipboardContent: String?
            let effectiveSelectedText: String?
            let effectiveSessionStartInputFieldState: SessionStartInputFieldState
            let effectivePreRecordingClipboard: String?
            let effectivePreRecordingClipboardStack: [String]
            let effectivePreRecordingChanges: [ClipboardChange]
            let effectivePreRecordingIgnoredReplayCount: Int
            let effectiveStartupReplayGuardEndsAt: Date?

            if let activeGroupId, var group = self.executionGroups[activeGroupId] {
                let wasPendingRestoreWindow = group.memberRecordingPaths.isEmpty &&
                    (group.pendingRestoreRecordingPath != nil || group.pendingFinalizationRecordingPath != nil)
                group.memberRecordingPaths.insert(recordingPath)
                if wasPendingRestoreWindow {
                    group.pendingRestoreRecordingPath = nil
                    group.pendingFinalizationRecordingPath = nil
                    logDebug("[ClipboardMonitor] Joined pending restore execution group \(activeGroupId) for \(recordingPath); canceled prior pending restore timing")
                }
                self.executionGroups[activeGroupId] = group
                self.recordingPathToGroupId[recordingPath] = activeGroupId
                groupId = activeGroupId
                effectiveLastCapturedClipboardContent = group.rootOriginalSnapshot?.legacyText
                effectiveSelectedText = group.rootSelectedText
                effectiveSessionStartInputFieldState = group.rootSessionStartInputFieldState
                effectivePreRecordingClipboard = group.rootPreRecordingClipboard
                effectivePreRecordingClipboardStack = group.rootPreRecordingClipboardStack
                effectivePreRecordingChanges = group.rootPreRecordingChanges
                effectivePreRecordingIgnoredReplayCount = group.rootPreRecordingIgnoredReplayCount
                effectiveStartupReplayGuardEndsAt = nil
                logDebug("[ClipboardMonitor] Joined execution group \(activeGroupId) for \(recordingPath); reusing root context from \(group.rootRecordingPath)")
            } else {
                groupId = UUID().uuidString
                let newGroup = ExecutionGroup(
                    id: groupId,
                    createdAt: sessionStartTime,
                    rootRecordingPath: recordingPath,
                    rootOriginalSnapshot: userOriginalSnapshot,
                    rootClipboardAttachmentsEnabled: self.clipboardAttachmentsEnabled,
                    rootClipboardStackingEnabled: false,
                    rootSelectedText: selectedText,
                    rootSessionStartInputFieldState: sessionStartInputFieldState,
                    rootPreRecordingClipboard: preRecordingClipboard,
                    rootPreRecordingClipboardStack: preRecordingClipboardStack,
                    rootPreRecordingChanges: preRecordingChanges,
                    rootPreRecordingIgnoredReplayCount: ignoredPreRecordingReplayCounts.count,
                    clipboardContextResetAt: nil,
                    memberRecordingPaths: [recordingPath],
                    pendingRestoreRecordingPath: nil,
                    pendingRestoreDelay: DEFAULT_CLIPBOARD_RESTORE_DELAY,
                    pendingCleanupDelay: DEFAULT_CLIPBOARD_RESTORE_DELAY + CLIPBOARD_CLEANUP_GRACE,
                    scriptResults: [],
                    finalizationToken: UUID().uuidString
                )
                self.executionGroups[groupId] = newGroup
                self.recordingPathToGroupId[recordingPath] = groupId
                effectiveLastCapturedClipboardContent = userOriginalSnapshot?.legacyText
                effectiveSelectedText = selectedText
                effectiveSessionStartInputFieldState = sessionStartInputFieldState
                effectivePreRecordingClipboard = preRecordingClipboard
                effectivePreRecordingClipboardStack = preRecordingClipboardStack
                effectivePreRecordingChanges = preRecordingChanges
                effectivePreRecordingIgnoredReplayCount = ignoredPreRecordingReplayCounts.count
                effectiveStartupReplayGuardEndsAt = startupReplayGuardEndsAt
                logDebug("[ClipboardMonitor] Created execution group \(groupId) with root \(recordingPath)")
            }

            let session = EarlyMonitoringSession(
                groupId: groupId,
                startTime: sessionStartTime,
                selectedText: effectiveSelectedText,
                sessionStartInputFieldState: effectiveSessionStartInputFieldState,
                preRecordingClipboard: effectivePreRecordingClipboard,
                preRecordingClipboardStack: effectivePreRecordingClipboardStack,
                preRecordingChanges: effectivePreRecordingChanges,
                preRecordingIgnoredReplayCount: effectivePreRecordingIgnoredReplayCount,
                startupReplayGuardEndsAt: effectiveStartupReplayGuardEndsAt,
                startingChangeCount: currentChangeCount,
                lastSeenChangeCount: currentChangeCount,
                lastCapturedClipboardContent: effectiveLastCapturedClipboardContent,
                lastCapturedClipboardPayload: originalPasteboardSnapshot?.payload,
                startupBootstrapState: activeGroupId == nil && sessionStartInputFieldState == .outsideInputField
                    ? startupBootstrapState
                    : nil,
                clipboardContextResetAt: self.executionGroups[groupId]?.clipboardContextResetAt
            )
            self.earlyMonitoringSessions[recordingPath] = session
        }

        // The new root original/frozen state is now part of the shared
        // monitor budget. Evict rolling observations before any later session
        // capture can make the total exceed the aggregate bound.
        enforceMonitorWideImageRetentionBudget()

        logDebug("[ClipboardMonitor] Started early monitoring for \(recordingPath)")
        logDebug("[ClipboardMonitor] Captured user original clipboard snapshot")
        logDebug("[ClipboardMonitor] Session-start input field state: \(sessionStartInputFieldState.logValue)")
        if let startupBootstrapState {
            logDebug(
                "[ClipboardMonitor] Startup clipboard bootstrap candidate " +
                "stableChangeCount=\(startupBootstrapState.stableGlobalChangeCount) " +
                "sessionChangeCount=\(startupBootstrapState.sessionSnapshotChangeCount) " +
                "stableFingerprint=\(startupBootstrapState.stableGlobalPayloadFingerprint) " +
                "sessionFingerprint=\(startupBootstrapState.sessionSnapshotPayloadFingerprint) " +
                "inputState=\(sessionStartInputFieldState.logValue)"
            )
        }
        if !selectedText.isEmpty {
            logDebug("[ClipboardMonitor] Captured selected text at recording start")
        }

        // Start monitoring clipboard changes (continues until session cleanup)
        monitorClipboardChangesForSession(recordingPath: recordingPath)
    }

    func getContextRootRecordingPath(for recordingPath: String) -> String {
        var resolvedPath = recordingPath
        sessionsQueue.sync {
            guard let groupId = recordingPathToGroupId[recordingPath],
                  let group = executionGroups[groupId] else {
                return
            }
            resolvedPath = group.rootRecordingPath
        }
        return resolvedPath
    }

    /// Updates the process-wide default used by newly observed operations. A
    /// root action may override this for its complete execution group through
    /// `configureRootClipboardPolicy`.
    func updateClipboardAttachments(enabled: Bool) {
        let wasEnabled = clipboardAttachmentsEnabled
        clipboardAttachmentsEnabled = enabled
        guard wasEnabled && !enabled else { return }

        // Active groups own their captured observations and original snapshot
        // until finalization. Keep those bytes intact so a root action that
        // opted in cannot lose its frozen handoff/restoration data merely
        // because a later process-wide configuration update opted out. Only
        // the unprotected rolling baseline is released immediately.
        globalHistoryQueue.sync(flags: .barrier) {
            for index in self.globalClipboardHistory.indices {
                self.globalClipboardHistory[index].payload = self.globalClipboardHistory[index].payload
                    .droppingRetainedImages(reason: .featureDisabled)
            }
            if let payload = self.lastSeenClipboardPayload {
                self.lastSeenClipboardPayload = payload.droppingRetainedImages(reason: .featureDisabled)
            }
        }
    }

    /// Freezes root-chain attachment and stacking policy. The root values are
    /// copied to overlap members and are never re-read from later action steps.
    func configureRootClipboardPolicy(
        for recordingPath: String,
        attachmentsEnabled: Bool,
        stackingEnabled: Bool
    ) {
        sessionsQueue.sync(flags: .barrier) {
            guard let groupId = recordingPathToGroupId[recordingPath],
                  var group = executionGroups[groupId] else { return }
            group.rootClipboardAttachmentsEnabled = attachmentsEnabled
            group.rootClipboardStackingEnabled = stackingEnabled
            self.executionGroups[groupId] = group
        }
    }

    /// Records the exact context boundary consumed by a watcher/action step.
    /// Attachment candidates are carried forward into finalization; no later
    /// pasteboard/history read is performed for handoff.
    func freezeClipboardContext(
        for recordingPath: String,
        swResult: String
    ) -> ClipboardContextSnapshot {
        getSessionClipboardContextSnapshot(for: recordingPath, swResult: swResult)
    }

    /// Marks an attachments-enabled execution path and its whole-chain outcome.
    /// Attachment handoff is independent of string placeholder consumption, and
    /// a final successful step cannot enable it when a prior step failed.
    func markAttachmentHandoffEligible(
        for recordingPath: String,
        consumer: ClipboardAttachmentHandoffConsumer = .explicit,
        wholeChainSucceeded: Bool,
        priorChainFailure: Bool = false,
        finalizationDelay: TimeInterval = DEFAULT_CLIPBOARD_RESTORE_DELAY
    ) {
        sessionsQueue.sync(flags: .barrier) {
            guard let groupId = recordingPathToGroupId[recordingPath],
                  var group = executionGroups[groupId] else { return }
            group.attachmentHandoffPolicy = updatedClipboardAttachmentHandoffPolicy(
                existing: group.attachmentHandoffPolicy,
                consumer: consumer,
                wholeChainSucceeded: wholeChainSucceeded,
                priorChainFailure: priorChainFailure
            )
            if group.attachmentHandoffPolicy.isEligible {
                group.pendingFinalizationRecordingPath = recordingPath
                group.pendingFinalizationDelay = max(0, finalizationDelay)
            }
            self.executionGroups[groupId] = group
        }
    }

    /// Permanently records a failed chain step for this execution group.
    func markClipboardChainStepResult(for recordingPath: String, succeeded: Bool) {
        sessionsQueue.sync(flags: .barrier) {
            guard let groupId = recordingPathToGroupId[recordingPath],
                  var group = executionGroups[groupId] else { return }
            if !succeeded {
                group.attachmentHandoffPolicy = ClipboardAttachmentHandoffPolicy(
                    enabled: group.attachmentHandoffPolicy.enabled,
                    consumer: group.attachmentHandoffPolicy.consumer,
                    wholeChainSucceeded: false,
                    priorChainFailure: true
                )
            }
            self.executionGroups[groupId] = group
        }
    }

    /// Forcefully ends recording groups during cancellation or recovery.
    ///
    /// Unlike `stopEarlyMonitoring`, this never preserves root context and never restores
    /// an old clipboard snapshot. The current pasteboard becomes the new global baseline.
    @discardableResult
    func abortExecutionGroups(
        containing recordingPaths: Set<String>,
        reason: String
    ) -> ClipboardRecoveryAbortSummary {
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string)
        let currentChangeCount = pasteboard.changeCount
        let resetAt = Date()

        var groupCount = 0
        var sessionCount = 0
        var clipboardChangeCount = 0
        var preRecordingItemCount = 0

        sessionsQueue.sync(flags: .barrier) {
            let targetedGroupIds = Set(recordingPaths.compactMap { recordingPathToGroupId[$0] })

            for groupId in targetedGroupIds {
                guard executionGroups[groupId] != nil else { continue }
                groupCount += 1

                let groupedPaths = Set(recordingPathToGroupId.compactMap { path, mappedGroupId in
                    mappedGroupId == groupId ? path : nil
                }).union(
                    earlyMonitoringSessions.compactMap { path, session in
                        session.groupId == groupId ? path : nil
                    }
                )

                for path in groupedPaths {
                    if let session = earlyMonitoringSessions[path] {
                        sessionCount += 1
                        clipboardChangeCount += session.clipboardChanges.count
                        preRecordingItemCount += session.preRecordingChanges.count
                    }
                    earlyMonitoringSessions.removeValue(forKey: path)
                    recordingPathToGroupId.removeValue(forKey: path)
                }

                executionGroups.removeValue(forKey: groupId)
            }

            // Also clean up any orphaned targeted sessions that lost their group mapping.
            for path in recordingPaths where earlyMonitoringSessions[path] != nil || recordingPathToGroupId[path] != nil {
                if let session = earlyMonitoringSessions[path] {
                    sessionCount += 1
                    clipboardChangeCount += session.clipboardChanges.count
                    preRecordingItemCount += session.preRecordingChanges.count
                }
                earlyMonitoringSessions.removeValue(forKey: path)
                recordingPathToGroupId.removeValue(forKey: path)
            }
        }

        globalHistoryQueue.sync(flags: .barrier) {
            globalClipboardHistory.removeAll()
            clipboardContextResetAt = resetAt
            lastSeenClipboardContent = currentClipboard
            lastSeenClipboardPayload = nil
            lastSeenChangeCount = currentChangeCount
            lastSeenClipboardChangeObservedAt = resetAt
            isFirstGlobalCheck = false
            resetIgnoredClipboardSequenceTrackers()
        }

        logInfo(
            "[ClipboardMonitor] Aborted \(groupCount) execution group(s) for recovery " +
            "(sessions: \(sessionCount), clipboard changes: \(clipboardChangeCount), " +
            "pre-recording items: \(preRecordingItemCount)); preserved current clipboard. Reason: \(reason)"
        )

        return ClipboardRecoveryAbortSummary(
            groupCount: groupCount,
            sessionCount: sessionCount,
            clipboardChangeCount: clipboardChangeCount,
            preRecordingItemCount: preRecordingItemCount
        )
    }

    /// Discards captured clipboard context and starts a fresh capture boundary.
    /// This never changes the user's actual pasteboard contents or restoration snapshot.
    @discardableResult
    func resetClipboardContextCapture(for recordingPath: String?) -> ClipboardContextResetScope {
        let resetAt = Date()
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string)
        let currentChangeCount = pasteboard.changeCount

        // Reset the rolling pre-recording buffer and baseline the current pasteboard.
        // Baseline prevents a copy that happened before this command from being rediscovered
        // by the next global polling pass.
        globalHistoryQueue.sync(flags: .barrier) {
            globalClipboardHistory.removeAll()
            clipboardContextResetAt = resetAt
            lastSeenClipboardContent = currentClipboard
            lastSeenClipboardPayload = nil
            lastSeenChangeCount = currentChangeCount
            lastSeenClipboardChangeObservedAt = resetAt
            isFirstGlobalCheck = false
            resetIgnoredClipboardSequenceTrackers()
        }
        var resetRootPath: String?
        sessionsQueue.sync(flags: .barrier) {
            guard let recordingPath,
                  let groupId = recordingPathToGroupId[recordingPath],
                  var group = executionGroups[groupId] else {
                return
            }

            resetRootPath = group.rootRecordingPath
            group.rootPreRecordingClipboard = nil
            group.rootPreRecordingClipboardStack.removeAll()
            group.rootPreRecordingChanges.removeAll()
            group.rootPreRecordingIgnoredReplayCount = 0
            group.clipboardContextResetAt = resetAt
            group.frozenContextSnapshot = nil
            group.attachmentHandoffPolicy = .disabled
            group.pendingFinalizationRecordingPath = nil
            executionGroups[groupId] = group

            for path in recordingPathToGroupId.compactMap({ $0.value == groupId ? $0.key : nil }) {
                guard var session = earlyMonitoringSessions[path] else { continue }
                session.clipboardChanges.removeAll()
                session.preRecordingClipboard = nil
                session.preRecordingClipboardStack.removeAll()
                session.preRecordingChanges.removeAll()
                session.preRecordingIgnoredReplayCount = 0
                session.startupReplayGuardEndsAt = nil
                session.startupBootstrapState = nil
                session.ignoredClipboardChangeCounts.removeAll()
                session.lastSeenChangeCount = currentChangeCount
                session.lastCapturedClipboardContent = currentClipboard
                session.lastCapturedClipboardPayload = nil
                session.frozenContextSnapshot = nil
                session.lastObservedClipboardActivityAt = nil
                session.lastDiagnosticClipboardChangeObservedAt = nil
                session.clipboardContextResetAt = resetAt
                earlyMonitoringSessions[path] = session
            }
        }
        if let resetRootPath {
            logInfo("[ClipboardMonitor] Reset clipboard context capture for active recording session: \(resetRootPath)")
            return .activeSession(recordingPath: resetRootPath)
        }

        logInfo("[ClipboardMonitor] Reset pre-recording clipboard context buffer")
        return .preRecordingBuffer
    }

    func appendScriptResult(_ result: String, for recordingPath: String) {
        let sanitized = sanitizeContextPlaceholderValue(result)
        sessionsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard let groupId = self.recordingPathToGroupId[recordingPath],
                  var group = self.executionGroups[groupId] else { return }
            group.scriptResults.append(sanitized)
            self.executionGroups[groupId] = group
        }
    }

    func getScriptResults(for recordingPath: String) -> [String] {
        var results: [String] = []
        sessionsQueue.sync {
            guard let groupId = recordingPathToGroupId[recordingPath],
                  let group = executionGroups[groupId] else { return }
            results = group.scriptResults
        }
        return results
    }

    func markAudioRecordingStarted(for recordingPath: String) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            let targetPath: String
            if let groupId = self.recordingPathToGroupId[recordingPath],
               let group = self.executionGroups[groupId] {
                targetPath = group.rootRecordingPath
            } else {
                targetPath = recordingPath
            }

            guard var session = self.earlyMonitoringSessions[targetPath],
                  session.isActive,
                  !session.hasAudioRecordingStarted else {
                return
            }

            session.hasAudioRecordingStarted = true
            self.earlyMonitoringSessions[targetPath] = session
            logDebug("[ClipboardMonitor] Audio recording started; bounded startup clipboard replay guard is unchanged for \(targetPath)")
        }
    }

    /// Marks the most recent session clipboard operation in the recent-activity window
    /// as system clipboard sync (e.g. Superwhisper) so it doesn't pollute clipboardContext.
    func markRecentClipboardActivityAsSystemSync(for recordingPath: String, within window: TimeInterval? = nil) {
        let effectiveWindow = max(0, window ?? recentClipboardActivityWindow)
        guard effectiveWindow > 0 else { return }
        let cutoff = Date().addingTimeInterval(-effectiveWindow)

        sessionsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            var targetSessionPath = recordingPath
            if let groupId = self.recordingPathToGroupId[recordingPath],
               let group = self.executionGroups[groupId] {
                targetSessionPath = group.rootRecordingPath
            }

            guard var session = self.earlyMonitoringSessions[targetSessionPath] else { return }
            guard let recentChange = session.clipboardChanges.last(where: { $0.timestamp >= cutoff }) else { return }

            session.ignoredClipboardChangeCounts.insert(recentChange.changeCount)
            self.earlyMonitoringSessions[targetSessionPath] = session
            logDebug("[ClipboardMonitor] Marked recent clipboard change as system sync for context filtering (changeCount: \(recentChange.changeCount))")
        }
    }

    /// Reconciles the pasteboard operation visible at the preparation boundary with
    /// the active session, then excludes the exact operation that published the
    /// Superwhisper result. This runs synchronously only after the existing sync
    /// check has completed; it never sleeps or introduces another polling window.
    private func reconcileSuperwhisperClipboardSync(
        for recordingPath: String,
        swResult: String,
        within window: TimeInterval? = nil,
        allowRecentSessionFallback: Bool = true
    ) -> Bool {
        let effectiveWindow = max(0, window ?? recentClipboardActivityWindow)
        guard effectiveWindow > 0 else { return false }
        let now = Date()
        let cutoff = now.addingTimeInterval(-effectiveWindow)
        let pasteboardSnapshot = captureClipboardPasteboardSnapshot(
            from: .general,
            source: "system-sync-reconcile",
            includeAttachments: clipboardAttachmentsEnabled,
            attachmentLimits: attachmentLimits
        )
        let currentClipboard = pasteboardSnapshot?.payload.textProjection(
            attachmentsEnabled: clipboardAttachmentsEnabled
        ) ?? (clipboardAttachmentsEnabled ? nil : pasteboardSnapshot?.content)

        var markedChangeCount: Int?
        var markedFromCurrentPasteboard = false
        sessionsQueue.sync(flags: .barrier) {
            var targetSessionPath = recordingPath
            if let groupId = recordingPathToGroupId[recordingPath],
               let group = executionGroups[groupId] {
                targetSessionPath = group.rootRecordingPath
            }

            guard var session = earlyMonitoringSessions[targetSessionPath], session.isActive else {
                return
            }

            if let pasteboardSnapshot,
               pasteboardSnapshot.changeCount != session.startingChangeCount,
               let currentClipboard,
               clipboardTextMatchesSuperwhisperResult(
                   currentClipboard,
                   swResult: swResult,
                   maxCompareChars: maxSwResultCompareChars
               ) {
                markedChangeCount = pasteboardSnapshot.changeCount
                markedFromCurrentPasteboard = true
                session.lastSeenChangeCount = pasteboardSnapshot.changeCount
                session.lastCapturedClipboardContent = currentClipboard
                session.lastCapturedClipboardPayload = pasteboardSnapshot.payload
                session.lastObservedClipboardActivityAt = now
            } else if allowRecentSessionFallback,
                      let recentChange = session.clipboardChanges.last(where: { $0.timestamp >= cutoff }) {
                markedChangeCount = recentChange.changeCount
            }

            guard let markedChangeCount else { return }
            session.ignoredClipboardChangeCounts.insert(markedChangeCount)
            earlyMonitoringSessions[targetSessionPath] = session
        }

        if let markedChangeCount {
            if markedFromCurrentPasteboard {
                logDebug(
                    "[ClipboardMonitor] Superwhisper clipboard result matched current pasteboard and was excluded from context " +
                    "(changeCount: \(markedChangeCount), match: current-pasteboard)"
                )
            } else {
                logDebug(
                    "[ClipboardMonitor] Superwhisper clipboard reconciliation used the recent-session fallback " +
                    "(changeCount: \(markedChangeCount), exactResultMatch: false)"
                )
            }
        } else {
            logDebug("[ClipboardMonitor] No recent Superwhisper clipboard sync required context filtering")
        }
        return markedFromCurrentPasteboard
    }

    /// Uses the existing first-action synchronization window, classifies the exact
    /// Superwhisper pasteboard operation, and freezes clipboard context afterward.
    /// The common recent-activity path has no intentional delay.
    func prepareClipboardContextForAction(
        for recordingPath: String,
        swResult: String,
        onReady: @escaping (ClipboardContextSnapshot) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // The result is commonly already on the pasteboard even when the
            // asynchronous sampler has not committed its observation yet. In
            // that case classify the exact operation and freeze immediately.
            if self.reconcileSuperwhisperClipboardSync(
                for: recordingPath,
                swResult: swResult,
                allowRecentSessionFallback: false
            ) {
                let snapshot = self.freezeClipboardContext(
                    for: recordingPath,
                    swResult: swResult
                )
                logDebug(
                    "[ClipboardMonitor] Prepared clipboard context after matching the current Superwhisper result " +
                    "(waitedMs: 0)"
                )
                onReady(snapshot)
                return
            }

            self.withSuperwhisperClipboardSync(
                recordingPath: recordingPath,
                shouldUseSuperwhisperSync: true
            ) { skippedWaitForRecentActivity in
                _ = self.reconcileSuperwhisperClipboardSync(
                    for: recordingPath,
                    swResult: swResult
                )
                let snapshot = self.freezeClipboardContext(
                    for: recordingPath,
                    swResult: swResult
                )
                logDebug(
                    "[ClipboardMonitor] Prepared clipboard context after Superwhisper synchronization fallback " +
                    "(skippedWaitForRecentActivity: \(skippedWaitForRecentActivity))"
                )
                onReady(snapshot)
            }
        }
    }
    
    /// Marks that action execution is starting (enables clipboard change logging)
    func startActionExecution(for recordingPath: String) {
        let actionStartedAt = Date()
        sessionsQueue.sync(flags: .barrier) {
            guard let groupId = recordingPathToGroupId[recordingPath] else {
                earlyMonitoringSessions[recordingPath]?.isExecutingAction = true
                earlyMonitoringSessions[recordingPath]?.startupReplayGuardEndsAt = nil
                earlyMonitoringSessions[recordingPath]?.startupBootstrapState = nil
                return
            }

            for path in recordingPathToGroupId.compactMap({ $0.value == groupId ? $0.key : nil }) {
                earlyMonitoringSessions[path]?.startupReplayGuardEndsAt = nil
                earlyMonitoringSessions[path]?.startupBootstrapState = nil
            }
            earlyMonitoringSessions[recordingPath]?.isExecutingAction = true
        }
        cancelInferredTransientRestoreCandidate(
            boundaryChangeCount: NSPasteboard.general.changeCount,
            observedAt: actionStartedAt
        )
        logDebug("[ClipboardMonitor] Startup clipboard replay guard ended at action execution for \(recordingPath)")
    }
    
    /// Marks that action execution is finished (disables clipboard change logging)
    func finishActionExecution(
        for recordingPath: String,
        shouldCleanup: Bool = true,
        cleanupDelay: TimeInterval? = nil
    ) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath]?.isExecutingAction = false
        }
        
        // Trigger cleanup of clipboard changes using restore-aware timing.
        if shouldCleanup {
            let resolvedDelay = max(0, cleanupDelay ?? (DEFAULT_CLIPBOARD_RESTORE_DELAY + CLIPBOARD_CLEANUP_GRACE))
            cleanupClipboardChangesAfterAction(for: recordingPath, after: resolvedDelay)
        }
    }
    
    /// Clears clipboard changes after action execution to prevent contamination of clipboardContext
    /// This addresses the issue where fast usage causes previous action results to contaminate the next clipboardContext
    /// Called 0.5s after action execution completes to account for 0.3s clipboard restoration + buffer
    private func cleanupClipboardChangesAfterAction(for recordingPath: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sessionsQueue.async(flags: .barrier) { [weak self] in
                guard let self = self,
                      var session = self.earlyMonitoringSessions[recordingPath],
                      session.isActive else { return }

                // Skip stale cleanup when overlap/chain state has moved on to a different
                // restore owner. This prevents an earlier dictation cleanup from clearing
                // root clipboard context needed by a newer overlapping dictation.
                if let groupId = self.recordingPathToGroupId[recordingPath],
                   let group = self.executionGroups[groupId] {
                    let hasActiveMembers = !group.memberRecordingPaths.isEmpty
                    let restoreOwnedByAnotherRecording =
                        (group.pendingRestoreRecordingPath != nil && group.pendingRestoreRecordingPath != recordingPath) ||
                        (group.pendingFinalizationRecordingPath != nil && group.pendingFinalizationRecordingPath != recordingPath)
                    if hasActiveMembers || restoreOwnedByAnotherRecording {
                        logDebug("[ClipboardMonitor] Skipping stale FULL RESET for \(recordingPath) due to active overlap/group ownership")
                        return
                    }
                }

                // FULL RESET: Clear ALL clipboard changes that might contain contaminated content from action execution
                let clearedSessionChanges = session.clipboardChanges.count
                session.clipboardChanges.removeAll()
                
                // FULL RESET: Clear ALL pre-recording clipboard content that might be contaminated from previous actions
                // This prevents previous action results from being used as "pre-recording" content in fast usage scenarios
                let hadPreRecordingClipboard = session.preRecordingClipboard != nil
                let preRecordingStackCount = session.preRecordingClipboardStack.count
                let preRecordingObservationCount = session.preRecordingChanges.count
                
                session.preRecordingClipboard = nil
                session.preRecordingClipboardStack = []
                session.preRecordingChanges = []
                session.preRecordingIgnoredReplayCount = 0
                session.startupReplayGuardEndsAt = nil
                
                // Update the session
                self.earlyMonitoringSessions[recordingPath] = session
                
                // FULL RESET: Clear ALL global clipboard history to prevent contamination
                // This ensures that any content that was restored or captured during action execution
                // won't appear in future clipboardContext placeholders
                var cleanedGlobalEntries = 0
                self.globalHistoryQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self else { return }
                    
                    // FULL RESET: Remove ALL global history entries, not just the last 2 seconds
                    let beforeCount = self.globalClipboardHistory.count
                    self.globalClipboardHistory.removeAll()
                    cleanedGlobalEntries = beforeCount
                    
                    // Reset the last seen content to prevent immediate re-capture of restored content
                    self.lastSeenClipboardContent = nil
                    self.lastSeenClipboardPayload = nil
                    self.lastSeenChangeCount = 0
                    self.lastSeenClipboardChangeObservedAt = nil
                    self.isFirstGlobalCheck = true
                    self.resetIgnoredClipboardSequenceTrackers()
                    
                    // Log cleanup details on main queue
                    DispatchQueue.main.async {
                        var cleanupMessages: [String] = []
                        if clearedSessionChanges > 0 {
                            cleanupMessages.append("\(clearedSessionChanges) session clipboard changes")
                        }
                        if hadPreRecordingClipboard {
                            cleanupMessages.append("pre-recording clipboard content")
                        }
                        if preRecordingStackCount > 0 {
                            cleanupMessages.append("\(preRecordingStackCount) pre-recording stack items")
                        }
                        if preRecordingObservationCount > 0 {
                            cleanupMessages.append("\(preRecordingObservationCount) preserved pre-recording observations")
                        }
                        if cleanedGlobalEntries > 0 {
                            cleanupMessages.append("\(cleanedGlobalEntries) global history entries (FULL RESET)")
                        }
                        
                        if !cleanupMessages.isEmpty {
                            logDebug("[ClipboardMonitor] FULL RESET: Cleaned up \(cleanupMessages.joined(separator: ", ")) after action execution to prevent clipboardContext contamination")
                        }
                    }
                }
                
                // RESET PERIODIC CLEANUP TIMER: Restart the periodic cleanup timer to start fresh
                // This ensures that the periodic cleanup doesn't interfere with the action execution cleanup
                DispatchQueue.main.async {
                    self.stopPeriodicCleanup()
                    self.startPeriodicCleanup()
                    logDebug("[ClipboardMonitor] Reset periodic cleanup timer after action execution")
                }
            }
        }
    }
    
    /// Stops early monitoring for a recording session (natural cleanup)
    func stopEarlyMonitoring(for recordingPath: String, onCompletion: (() -> Void)? = nil) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let hadTrackedState = self.earlyMonitoringSessions[recordingPath] != nil || self.recordingPathToGroupId[recordingPath] != nil
            guard let groupId = self.recordingPathToGroupId[recordingPath],
                  var group = self.executionGroups[groupId] else {
                self.earlyMonitoringSessions.removeValue(forKey: recordingPath)
                self.recordingPathToGroupId.removeValue(forKey: recordingPath)
                if hadTrackedState {
                    logDebug("[ClipboardMonitor] Stopped early monitoring for \(recordingPath)")
                }
                DispatchQueue.main.async { onCompletion?() }
                return
            }

            group.memberRecordingPaths.remove(recordingPath)
            let shouldFinalize = group.memberRecordingPaths.isEmpty
            let isRootRecording = recordingPath == group.rootRecordingPath
            let shouldPreserveRootContext = isRootRecording &&
                (!shouldFinalize || group.pendingRestoreRecordingPath != nil || group.pendingFinalizationRecordingPath != nil)

            if shouldPreserveRootContext {
                if var rootSession = self.earlyMonitoringSessions[recordingPath] {
                    // Keep root session alive while overlap/pending-restore chain is still active.
                    rootSession.isActive = true
                    rootSession.isExecutingAction = false
                    self.earlyMonitoringSessions[recordingPath] = rootSession
                }
                logDebug("[ClipboardMonitor] Detached root recording \(recordingPath) while preserving its context for an active overlap")
            } else {
                self.earlyMonitoringSessions[recordingPath]?.isActive = false
                self.earlyMonitoringSessions.removeValue(forKey: recordingPath)
                self.recordingPathToGroupId.removeValue(forKey: recordingPath)
            }
            self.executionGroups[groupId] = group
            if !shouldPreserveRootContext {
                logDebug("[ClipboardMonitor] Stopped early monitoring for \(recordingPath)")
            }

            if shouldFinalize {
                self.finalizeExecutionGroup(groupId: groupId, onCompletion: onCompletion)
            } else {
                DispatchQueue.main.async { onCompletion?() }
            }
        }
    }

    private func finalizeExecutionGroup(groupId: String, onCompletion: (() -> Void)? = nil) {
        guard let group = executionGroups[groupId] else {
            DispatchQueue.main.async { onCompletion?() }
            return
        }

        let finalize = { [weak self] in
            guard let self else { return }
            // All operations that need both queues use global -> sessions
            // ordering. Holding the global barrier through validation, the
            // pasteboard transition, and history reset prevents a new session
            // from seeding itself with history from the group being finalized.
            self.globalHistoryQueue.async(flags: .barrier) {
                self.sessionsQueue.sync(flags: .barrier) {
                    guard let currentGroup = self.executionGroups[groupId],
                      currentGroup.finalizationToken == group.finalizationToken,
                      currentGroup.memberRecordingPaths.isEmpty else {
                    // A new overlap/group owner won the boundary; stale delayed
                    // work must not restore or hand off anything.
                    DispatchQueue.main.async { onCompletion?() }
                    return
                }
                let expectedPath = group.pendingRestoreRecordingPath ?? group.pendingFinalizationRecordingPath
                let currentOwner = currentGroup.pendingRestoreRecordingPath ?? currentGroup.pendingFinalizationRecordingPath
                if let expectedPath,
                   currentOwner != expectedPath {
                    DispatchQueue.main.async { onCompletion?() }
                    return
                }

                let policy = currentGroup.attachmentHandoffPolicy
                let snapshot = currentGroup.frozenContextSnapshot
                let selectedPayload: ClipboardPayload? = {
                    guard currentGroup.rootClipboardAttachmentsEnabled,
                          policy.isEligible,
                          let snapshot else { return nil }
                    let candidates = currentGroup.rootClipboardStackingEnabled
                        ? snapshot.stackedAttachmentCandidates
                        : snapshot.singleAttachmentCandidates
                    guard !candidates.isEmpty else { return nil }
                    let items = candidates.flatMap(\.items)
                    guard !items.isEmpty else { return nil }
                    return ClipboardPayload(items: items, legacyText: nil)
                }()
                let shouldRestore = currentGroup.pendingRestoreRecordingPath != nil
                let originalSnapshot = currentGroup.rootOriginalSnapshot

                // Suppression and the native write happen while ownership is
                // still held by this group, before it is removed. This closes
                // the race where delayed finalization could overwrite a newer
                // group's clipboard.
                if let selectedPayload {
                    let preparedHandoff = self.attachmentFileStore.prepare(selectedPayload)
                    let writtenPayload = preparedHandoff.clipboardPayload
                    let commitResult = self.attachmentFileStore.commitResult(preparedHandoff)
                    if commitResult == .committed {
                        self.suppressNextClipboardCapture(for: writtenPayload, duration: 1.5)
                        logDebug(
                            "[ClipboardMonitor] Handed off clipboard attachments as one ordered file list " +
                            "(files: \(preparedHandoff.fileURLs.count), sourceAttachments: " +
                            "\(preparedHandoff.sourceAttachmentCount), materializedImages: " +
                            "\(preparedHandoff.materializedImageCount), transcodedTIFFImages: " +
                            "\(preparedHandoff.transcodedTIFFImageCount), imageNormalizationFailures: " +
                            "\(preparedHandoff.imageNormalizationFailureCount), sourceImageBytes: " +
                            "\(preparedHandoff.sourceImageByteCount), generatedImageBytes: " +
                            "\(preparedHandoff.generatedImageByteCount), materializationFailures: " +
                            "\(preparedHandoff.materializationFailureCount), generation: " +
                            "\(preparedHandoff.generationIdentifier), generatedFilesPresent: " +
                            "\(preparedHandoff.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }), " +
                            "cacheRetentionHours: 24, cacheLimitMiB: 1024, " +
                            "fingerprint: \(writtenPayload.fingerprint))"
                        )
                        let omittedAttachmentCount = max(
                            selectedPayload.unavailableAttachmentCount,
                            preparedHandoff.materializationFailureCount
                        )
                        if omittedAttachmentCount > 0 {
                            logDebug(
                                "[ClipboardMonitor] Attachment handoff omitted unavailable items " +
                                "(reason: bounded-or-unavailable, unavailableAttachments: " +
                                "\(omittedAttachmentCount), dropReasons: " +
                                "\(makeClipboardPayloadDiagnosticMetadata(selectedPayload).dropReasons), " +
                                "fingerprint: \(selectedPayload.fingerprint))"
                            )
                        }
                    } else {
                        logDebug(
                            "[ClipboardMonitor] Attachment handoff omitted unavailable items " +
                            "(reason: no-writable-representation, unavailableAttachments: " +
                            "\(max(selectedPayload.unavailableAttachmentCount, preparedHandoff.materializationFailureCount)), " +
                            "dropReasons: " +
                            "\(makeClipboardPayloadDiagnosticMetadata(selectedPayload).dropReasons), " +
                            "fingerprint: \(selectedPayload.fingerprint))"
                        )
                        if shouldRestore, commitResult == .noWritableAttachments {
                            self.restoreCorrectClipboard(originalSnapshot)
                        } else if commitResult == .preservedCurrentClipboard {
                            logDebug(
                                "[ClipboardMonitor] Original clipboard restoration skipped " +
                                "(reason: attachment-handoff-preserved-newer-current-clipboard)"
                            )
                        }
                    }
                } else if shouldRestore {
                    self.restoreCorrectClipboard(originalSnapshot)
                }

                let cleanedGlobalEntries = self.globalClipboardHistory.count
                self.globalClipboardHistory.removeAll()
                self.lastSeenClipboardContent = nil
                self.lastSeenClipboardPayload = nil
                self.lastSeenChangeCount = 0
                self.lastSeenClipboardChangeObservedAt = nil
                self.isFirstGlobalCheck = true
                self.resetIgnoredClipboardSequenceTrackers()
                if cleanedGlobalEntries > 0 {
                    logDebug("[ClipboardMonitor] FULL RESET: Cleaned up \(cleanedGlobalEntries) global history entries after execution group finalization")
                }

                let staleRecordingPaths = self.recordingPathToGroupId
                    .filter { $0.value == groupId }
                    .map { $0.key }
                for path in staleRecordingPaths {
                    self.recordingPathToGroupId.removeValue(forKey: path)
                    self.earlyMonitoringSessions.removeValue(forKey: path)
                }
                self.executionGroups.removeValue(forKey: groupId)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.cleanupGeneratedAttachmentFilesIfIdle()
                }
                DispatchQueue.main.async { onCompletion?() }
                }
            }
        }

        if group.pendingRestoreRecordingPath != nil || group.pendingFinalizationRecordingPath != nil {
            let delay = group.pendingRestoreRecordingPath != nil
                ? group.pendingRestoreDelay
                : group.pendingFinalizationDelay
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, delay),
                execute: finalize
            )
        } else {
            finalize()
        }
    }

    private func markGroupRestoreIntent(
        for recordingPath: String,
        shouldRestoreClipboard: Bool,
        restoreDelay: TimeInterval
    ) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard let groupId = self.recordingPathToGroupId[recordingPath],
                  var group = self.executionGroups[groupId] else { return }

            if shouldRestoreClipboard {
                group.pendingRestoreRecordingPath = recordingPath
                group.pendingRestoreDelay = max(0, restoreDelay)
                group.pendingCleanupDelay = max(0, restoreDelay + CLIPBOARD_CLEANUP_GRACE)
            } else {
                group.pendingRestoreRecordingPath = nil
                group.pendingCleanupDelay = max(group.pendingCleanupDelay, CLIPBOARD_CLEANUP_GRACE)
            }
            if group.attachmentHandoffPolicy.isEligible {
                group.pendingFinalizationRecordingPath = recordingPath
                group.pendingFinalizationDelay = max(0, restoreDelay)
            } else if !shouldRestoreClipboard {
                group.pendingFinalizationRecordingPath = nil
            }
            self.executionGroups[groupId] = group
        }
    }
    
    /// Gets the selected text that was captured when the recording session started
    /// Returns empty string if no session exists or no text was selected
    func getSessionSelectedText(for recordingPath: String) -> String {
        var selectedText = ""
        sessionsQueue.sync {
            selectedText = earlyMonitoringSessions[recordingPath]?.selectedText ?? ""
        }
        return sanitizeContextPlaceholderValue(selectedText)
    }
    
    /// Gets the last clipboard content that was captured during the monitoring session
    /// Enhanced to also consider clipboard content from before recording started
    /// Returns empty string if no relevant clipboard changes occurred
    func getSessionClipboardContent(for recordingPath: String, swResult: String) -> String {
        getSessionClipboardContextRepresentations(for: recordingPath, swResult: swResult).single
    }

    /// Captures the text projections and attachment candidates at one boundary.
    /// Callers that execute a chain should retain this value and hand it back to
    /// `markAttachmentHandoffEligible`; finalization never re-reads history.
    func getSessionClipboardContextSnapshot(
        for recordingPath: String,
        swResult: String
    ) -> ClipboardContextSnapshot {
        let snapshot = boundedFrozenContextSnapshot(
            buildSessionClipboardContextSnapshot(
                for: recordingPath,
                swResult: swResult
            ),
            for: recordingPath
        )
        enforceMonitorWideImageRetentionBudget()
        return snapshot
    }

    /// Freezes both clipboardContext projections from the same ordered, filtered candidate set.
    /// The selected action can then choose single or stacked output without changing the capture boundary.
    func getSessionClipboardContextRepresentations(
        for recordingPath: String,
        swResult: String
    ) -> ClipboardContextRepresentations {
        getSessionClipboardContextSnapshot(for: recordingPath, swResult: swResult).representations
    }

    private func buildSessionClipboardContextSnapshot(
        for recordingPath: String,
        swResult: String
    ) -> ClipboardContextSnapshot {
        var projectionAttachmentsEnabled = clipboardAttachmentsEnabled
        sessionsQueue.sync {
            if let groupId = recordingPathToGroupId[recordingPath],
               let group = executionGroups[groupId] {
                projectionAttachmentsEnabled = group.rootClipboardAttachmentsEnabled
            }
        }
        var candidates: [String] = []
        var orderedPayloads: [ClipboardPayload] = []
        var preRecordingCount = 0
        var preRecordingIgnoredReplayCount = 0
        var sessionChangeCount = 0
        var ignoredChangeCount = 0
        var missingContentCount = 0
        var resetExcludedCount = 0

        sessionsQueue.sync {
            guard let session = earlyMonitoringSessions[recordingPath] else { return }
            preRecordingIgnoredReplayCount = session.preRecordingIgnoredReplayCount

            if session.clipboardContextResetAt == nil {
                let eligiblePreRecordingChanges = session.preRecordingChanges.filter {
                    !session.ignoredClipboardChangeCounts.contains($0.changeCount)
                }
                for change in eligiblePreRecordingChanges {
                    orderedPayloads.append(change.payload)
                    if let content = change.payload.textProjection(
                        attachmentsEnabled: projectionAttachmentsEnabled
                    ) ?? change.content {
                        candidates.append(content)
                    }
                }
                preRecordingCount = eligiblePreRecordingChanges.count

                // Defensive fallback for legacy state that has a stack but no
                // preserved observations.
                if eligiblePreRecordingChanges.isEmpty {
                    candidates.append(contentsOf: session.preRecordingClipboardStack)
                    preRecordingCount = session.preRecordingClipboardStack.count
                }
            }

                for change in session.clipboardChanges {
                sessionChangeCount += 1
                if session.ignoredClipboardChangeCounts.contains(change.changeCount) {
                    ignoredChangeCount += 1
                    continue
                }
                guard shouldIncludeClipboardChange(
                    timestamp: change.timestamp,
                    resetAt: session.clipboardContextResetAt
                ) else {
                    resetExcludedCount += 1
                    continue
                }
                orderedPayloads.append(change.payload)
                guard let content = change.payload.textProjection(
                    attachmentsEnabled: projectionAttachmentsEnabled
                ) ?? change.content else {
                    missingContentCount += 1
                    continue
                }
                candidates.append(content)
            }
        }

        let snapshot = makeClipboardOperationContextSnapshot(
            orderedPayloads: orderedPayloads,
            fallbackTextCandidates: candidates,
            swResult: swResult,
            attachmentsEnabled: projectionAttachmentsEnabled,
            maxSwResultCompareChars: maxSwResultCompareChars
        )
        let representations = snapshot.representations

        if preRecordingCount > 0 {
            logDebug("[ClipboardMonitor] Added \(preRecordingCount) pre-recording clipboard item(s) from within the buffer window")
        }
        if preRecordingIgnoredReplayCount > 0 {
            logDebug("[ClipboardMonitor] Excluded \(preRecordingIgnoredReplayCount) pre-recording startup replay(s) from clipboard context")
        }
        if representations.single.isEmpty {
            logNoContentIfNeeded(
                "session_no_content",
                "[ClipboardMonitor] No eligible clipboard content found after filtering " +
                "(sessionChanges: \(sessionChangeCount), ignored: \(ignoredChangeCount), " +
                "missingContent: \(missingContentCount), resetExcluded: \(resetExcludedCount), " +
                "preRecording: \(preRecordingCount), preRecordingStartupReplays: \(preRecordingIgnoredReplayCount))"
            )
        }
        if !candidates.isEmpty {
            let contextAgeMilliseconds: Int = sessionsQueue.sync {
                guard let session = earlyMonitoringSessions[recordingPath] else { return 0 }
                let oldestTimestamp = session.clipboardChanges
                    .filter { !session.ignoredClipboardChangeCounts.contains($0.changeCount) }
                    .map(\.timestamp)
                    .min() ?? session.startTime
                return Int(max(0, Date().timeIntervalSince(oldestTimestamp)) * 1_000)
            }
            logDebug(
                "[ClipboardMonitor] Built clipboard context snapshot from \(candidates.count) candidate(s); " +
                "oldest eligible session activity age: \(contextAgeMilliseconds)ms; root: \(recordingPath)"
            )
        }

        return snapshot
    }
    
    /// Gets clipboard content with stacking support - returns all clipboard changes when stacking is enabled
    /// - Parameters:
    ///   - recordingPath: The recording path to get session data from
    ///   - swResult: The Superwhisper result to filter out
    ///   - enableStacking: Whether to enable clipboard stacking (from configuration)
    /// - Returns: Formatted clipboard content (single content or XML-tagged stack)
    func getSessionClipboardContentWithStacking(for recordingPath: String, swResult: String, enableStacking: Bool) -> String {
        let representations = getSessionClipboardContextRepresentations(
            for: recordingPath,
            swResult: swResult
        )
        return representations.value(enableStacking: enableStacking)
    }

    /// Gets selected text from the most recent active recording session for CLI usage.
    /// Returns empty string when no active session exists or no selection was captured.
    func getActiveSessionSelectedText() -> String {
        var selectedText = ""
        sessionsQueue.sync {
            let activeSession = earlyMonitoringSessions.values
                .filter { $0.isActive }
                .max(by: { $0.startTime < $1.startTime })
            selectedText = activeSession?.selectedText ?? ""
        }
        return sanitizeContextPlaceholderValue(selectedText)
    }

    /// Gets the recording path for the most recent active recording session.
    /// Returns nil when no active session exists.
    func getMostRecentActiveRecordingPath() -> String? {
        var resolvedPath: String?
        sessionsQueue.sync {
            resolvedPath = earlyMonitoringSessions
                .filter { $0.value.isActive }
                .max(by: { $0.value.startTime < $1.value.startTime })?
                .key
        }
        return resolvedPath
    }

    /// Gets clipboard context from the most recent active recording session for CLI usage.
    /// This intentionally does not depend on meta.json and reflects session state at call-time.
    func getActiveSessionClipboardContentWithStacking(enableStacking: Bool) -> String {
        guard let recordingPath = getMostRecentActiveRecordingPath() else { return "" }
        return getSessionClipboardContentWithStacking(
            for: recordingPath,
            swResult: "",
            enableStacking: enableStacking
        )
    }
    
    /// Gets the most recent clipboard content from global history for CLI execution context
    /// This is used when --exec-action is called and there's no recording session
    /// Returns empty string if no recent clipboard changes found
    func getRecentClipboardContent() -> String {
        var recentContent = ""
        
        // If buffer disabled, return empty to avoid using global history
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Global clipboard buffer disabled - no recent clipboard content available for CLI context")
            return ""
        }

        globalHistoryQueue.sync {
            // Find the most recent clipboard change within the 5-second buffer
            if let mostRecent = globalClipboardHistory.last(where: {
                shouldIncludeClipboardChange(timestamp: $0.timestamp, resetAt: clipboardContextResetAt)
            }) {
                let timeSinceLastChange = Date().timeIntervalSince(mostRecent.timestamp)
                if timeSinceLastChange <= preRecordingBuffer {
                    recentContent = mostRecent.payload.textProjection(
                        attachmentsEnabled: clipboardAttachmentsEnabled
                    ) ?? mostRecent.content ?? ""
                    logDebug("[ClipboardMonitor] Using recent clipboard content from \(String(format: "%.1f", timeSinceLastChange))s ago for CLI context")
                } else {
                    logNoContentIfNeeded(
                        "cli_context_too_old",
                        "[ClipboardMonitor] Last clipboard change was \(String(format: "%.1f", timeSinceLastChange))s ago (older than buffer)"
                    )
                }
            } else {
                logNoContentIfNeeded(
                    "cli_context_no_history",
                    "[ClipboardMonitor] No clipboard changes found in global history for CLI context"
                )
            }
        }
        
        return sanitizeContextPlaceholderValue(recentContent)
    }
    
    /// Gets clipboard content from global history for CLI execution context with stacking support
    /// This is used when --exec-action is called and there's no recording session
    /// - Parameter enableStacking: Whether to enable clipboard stacking (from configuration)
    /// - Returns: Formatted clipboard content (single content or XML-tagged stack)
    func getRecentClipboardContentWithStacking(enableStacking: Bool) -> String {
        // If stacking is disabled, use the original behavior
        if !enableStacking {
            return getRecentClipboardContent()
        }
        
        // If buffer disabled, return empty to avoid using global history
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Global clipboard buffer disabled - no recent clipboard content available for CLI stacking")
            return ""
        }

        var allClipboardChanges: [String] = []
        
        globalHistoryQueue.sync {
            // Find all clipboard changes within the 5-second buffer
            let now = Date()
            let cutoffTime = now.addingTimeInterval(-preRecordingBuffer)
            
            let recentChanges = globalClipboardHistory.filter { change in
                change.timestamp >= cutoffTime &&
                    shouldIncludeClipboardChange(
                        timestamp: change.timestamp,
                        resetAt: clipboardContextResetAt
                    )
            }
            
            // Add all recent changes (excluding empty content)
            for change in recentChanges {
                if let content = change.payload.textProjection(
                    attachmentsEnabled: clipboardAttachmentsEnabled
                ) ?? change.content {
                    let normalized = sanitizeContextPlaceholderValue(content)
                    if !normalized.isEmpty {
                        allClipboardChanges.append(normalized)
                    }
                }
            }
        }
        
        // Format the result based on number of clipboard changes
        if allClipboardChanges.isEmpty {
            logNoContentIfNeeded(
                "cli_stacking_no_history",
                "[ClipboardMonitor] No clipboard content found in global history for CLI stacking"
            )
            return ""
        } else if allClipboardChanges.count == 1 {
            // Single clipboard change - return without XML tags (maintains current behavior)
            logDebug("[ClipboardMonitor] Single clipboard change for CLI stacking - returning without XML tags")
            return allClipboardChanges[0]
        } else {
            // Multiple clipboard changes - format with XML tags
            var result = ""
            for (index, content) in allClipboardChanges.enumerated() {
                let tagNumber = index + 1
                result += "<clipboard-context-\(tagNumber)>\n\(content)\n</clipboard-context-\(tagNumber)>\n\n"
            }
            logDebug("[ClipboardMonitor] Multiple clipboard changes for CLI stacking - formatted with \(allClipboardChanges.count) XML tags")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    /// Captures complete observations from the configured buffer before recording starts.
    /// Full metadata is retained so same-content startup replays can be filtered retroactively.
    private func capturePreRecordingClipboardChanges(beforeTime sessionStartTime: Date) -> [ClipboardChange] {
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Pre-recording clipboard buffer disabled - skipping pre-recording capture")
            return []
        }

        let bufferStartTime = sessionStartTime.addingTimeInterval(-preRecordingBuffer)
        var capturedChanges: [ClipboardChange] = []
        globalHistoryQueue.sync {
            capturedChanges = globalClipboardHistory.filter { change in
                change.timestamp >= bufferStartTime &&
                    change.timestamp < sessionStartTime &&
                    shouldIncludeClipboardChange(
                        timestamp: change.timestamp,
                        resetAt: clipboardContextResetAt
                    )
            }
        }

        if let oldest = capturedChanges.first {
            let timeBeforeRecording = sessionStartTime.timeIntervalSince(oldest.timestamp)
            logDebug(
                "[ClipboardMonitor] Preserved \(capturedChanges.count) pre-recording clipboard observation(s) " +
                "from up to \(String(format: "%.1f", timeBeforeRecording))s before recording"
            )
        } else {
            logNoContentIfNeeded(
                "pre_recording_no_history",
                "[ClipboardMonitor] No clipboard changes found within buffer window before recording started"
            )
        }

        return capturedChanges
    }
    
    /// Monitors clipboard changes during early monitoring session
    private func monitorClipboardChangesForSession(recordingPath: String) {
        // Get session data in a single atomic operation to prevent race conditions
        var sessionData: (
            isActive: Bool,
            isRootSession: Bool,
            isExecutingAction: Bool,
            lastSeenChangeCount: Int,
            lastCapturedClipboardContent: String?,
            lastCapturedClipboardPayload: ClipboardPayload?,
            lastDiagnosticClipboardChangeObservedAt: Date?,
            startupBootstrapState: StartupClipboardBootstrapState?
        ) = (false, false, false, 0, nil, nil, nil, nil)
        
        sessionsQueue.sync { [weak self] in
            guard let session = self?.earlyMonitoringSessions[recordingPath] else { return }
            sessionData.isActive = session.isActive
            if let group = self?.executionGroups[session.groupId] {
                sessionData.isRootSession = (group.rootRecordingPath == recordingPath)
            }
            sessionData.isExecutingAction = session.isExecutingAction
            sessionData.lastSeenChangeCount = session.lastSeenChangeCount
            sessionData.lastCapturedClipboardContent = session.lastCapturedClipboardContent
            sessionData.lastCapturedClipboardPayload = session.lastCapturedClipboardPayload
            sessionData.lastDiagnosticClipboardChangeObservedAt = session.lastDiagnosticClipboardChangeObservedAt
            sessionData.startupBootstrapState = session.startupBootstrapState
        }
        
        // Exit silently if session is not active - session will be cleaned up naturally
        guard sessionData.isActive else { 
            return 
        }

        // Overlapping sessions reuse root dictation context and must not capture new clipboard context.
        if !sessionData.isRootSession {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
            return
        }
        
        let pasteboard = NSPasteboard.general
        guard let pasteboardSnapshot = captureClipboardPasteboardSnapshot(
            from: pasteboard,
            source: "session",
            includeAttachments: clipboardAttachmentsEnabled,
            attachmentLimits: attachmentLimits
        ) else {
            logNoContentIfNeeded(
                "session_unstable_pasteboard_snapshot",
                "[ClipboardMonitor] Session monitoring deferred an unstable pasteboard snapshot"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
            return
        }
        let currentChangeCount = pasteboardSnapshot.changeCount
        let currentClipboard = pasteboardSnapshot.payload.textProjection(
            attachmentsEnabled: clipboardAttachmentsEnabled
        ) ?? (clipboardAttachmentsEnabled ? nil : pasteboardSnapshot.content)

        if let startupBootstrapState = sessionData.startupBootstrapState,
           currentChangeCount != startupBootstrapState.sessionSnapshotChangeCount,
           self.reconcileStartupClipboardBootstrapRestore(
               for: recordingPath,
               observedSnapshot: pasteboardSnapshot,
               observedAt: Date()
           ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
            return
        }
        
        // Use changeCount for more reliable change detection
        if currentChangeCount != sessionData.lastSeenChangeCount {
            let now = Date()

            logClipboardObservationDiagnostic(
                source: "session",
                snapshot: pasteboardSnapshot,
                observedAt: now,
                previousChangeCount: sessionData.lastSeenChangeCount,
                previousObservedAt: sessionData.lastDiagnosticClipboardChangeObservedAt,
                previousContent: sessionData.lastCapturedClipboardContent
            )
            sessionsQueue.async(flags: .barrier) { [weak self] in
                guard let self,
                      var session = self.earlyMonitoringSessions[recordingPath],
                      session.isActive else {
                    return
                }
                session.lastDiagnosticClipboardChangeObservedAt = now
                self.earlyMonitoringSessions[recordingPath] = session
            }

            if shouldSuppressClipboardCapture(
                content: currentClipboard,
                payload: pasteboardSnapshot.payload,
                now: now
            ) {
                self.cancelInferredTransientRestoreCandidate(
                    boundaryChangeCount: currentChangeCount,
                    observedAt: now
                )
                sessionsQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self,
                          var session = self.earlyMonitoringSessions[recordingPath],
                          session.isActive else {
                        return
                    }

                    session.lastSeenChangeCount = currentChangeCount
                    session.lastCapturedClipboardContent = currentClipboard
                    session.lastCapturedClipboardPayload = pasteboardSnapshot.payload
                    self.earlyMonitoringSessions[recordingPath] = session
                }
                logDebug("[ClipboardMonitor] Session monitoring skipped Macrowhisper copy-action clipboard write")
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                    self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
                }
                return
            }

            let ignoredMarkerType = self.ignoredMarkerType(in: pasteboardSnapshot.types)
            let markerSequenceDecision = self.ignoredMarkerSequenceDecision(
                changeCount: currentChangeCount,
                containsIgnoredMarker: ignoredMarkerType != nil,
                observedAt: now
            )
            self.logMarkerSequenceDecision(
                markerSequenceDecision,
                markerType: ignoredMarkerType,
                changeCount: currentChangeCount,
                source: "Session monitoring"
            )
            if markerSequenceDecision.shouldIgnore {
                self.cancelInferredTransientRestoreCandidate(
                    boundaryChangeCount: currentChangeCount,
                    observedAt: now
                )
                self.noteRecentClipboardActivity(
                    for: recordingPath,
                    changeCount: currentChangeCount,
                    timestamp: now
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                    self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
                }
                return
            }

            let isSameContentRewrite: Bool
            if sessionData.lastCapturedClipboardPayload != nil {
                isSameContentRewrite = isSameClipboardPayloadRewrite(
                    currentPayload: pasteboardSnapshot.payload,
                    previousPayload: sessionData.lastCapturedClipboardPayload
                )
            } else {
                isSameContentRewrite = isSameContentClipboardRewrite(
                    currentClipboard: currentClipboard,
                    previousClipboard: sessionData.lastCapturedClipboardContent
                )
            }

            // A startup restore may itself look like a same-content replay. Give an
            // already-armed transaction the first chance to classify that restoring
            // write so the global sampler cannot hide it from the session sampler.
            let pendingRestoreDecision = self.inferredTransientRestoreDecision(
                changeCount: currentChangeCount,
                content: currentClipboard,
                payload: pasteboardSnapshot.payload,
                containsIgnoredMarker: false,
                observedAt: now,
                previousChangeCount: sessionData.lastSeenChangeCount,
                previousContent: sessionData.lastCapturedClipboardContent,
                previousPayload: sessionData.lastCapturedClipboardPayload,
                canArmCandidate: false
            )
            self.logInferredTransientRestoreDecision(
                pendingRestoreDecision,
                source: "Session monitoring"
            )
            if pendingRestoreDecision.shouldIgnore {
                let transactionChangeCounts = pendingRestoreDecision.transactionChangeCounts
                self.globalHistoryQueue.sync(flags: .barrier) {
                    self.removeInferredTransientTransactionFromGlobalHistory(transactionChangeCounts)
                }
                self.excludeInferredTransientTransactionFromSessions(transactionChangeCounts)
                self.noteRecentClipboardActivity(
                    for: recordingPath,
                    changeCount: currentChangeCount,
                    timestamp: now,
                    lastCapturedClipboardContent: currentClipboard,
                    lastCapturedClipboardPayload: pasteboardSnapshot.payload
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                    self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
                }
                return
            }

            if self.shouldIgnoreStartupClipboardReplayForSession(
                recordingPath: recordingPath,
                isSameContentRewrite: isSameContentRewrite,
                changeCount: currentChangeCount,
                observedAt: now
            ) {
                self.cancelInferredTransientRestoreCandidate(
                    boundaryChangeCount: currentChangeCount,
                    observedAt: now
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                    self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
                }
                return
            }
            
            // Capture the current front-app identity immediately when the clipboard changes.
            // This preserves app attribution without paying the focused-element AX cost here.
            let frontApp = resolveFrontAppIdentity()
            let appName = frontApp?.localizedName ?? ""
            let bundleId = frontApp?.bundleIdentifier ?? ""

            // Check if the captured app should be ignored (using the app info we captured atomically)
            let shouldIgnoreAppFlag = self.shouldIgnoreApp(appName: appName, bundleId: bundleId)
            let observationDecision = decideSessionClipboardObservation(
                shouldIgnoreApp: shouldIgnoreAppFlag,
                containsIgnoredMarker: false
            )

            if observationDecision.shouldCaptureInSessionHistory {
                let allowAdjacentStartupCandidate = self.allowsAdjacentStartupTransientCandidate(
                    for: recordingPath,
                    changeCount: currentChangeCount,
                    observedAt: now
                )
                let inferredRestoreDecision = self.inferredTransientRestoreDecision(
                    changeCount: currentChangeCount,
                    content: currentClipboard,
                    payload: pasteboardSnapshot.payload,
                    containsIgnoredMarker: false,
                    observedAt: now,
                    previousChangeCount: sessionData.lastSeenChangeCount,
                    previousContent: sessionData.lastCapturedClipboardContent,
                    previousPayload: sessionData.lastCapturedClipboardPayload,
                    restoreWindow: allowAdjacentStartupCandidate
                        ? ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW
                        : INFERRED_TRANSIENT_RESTORE_WINDOW,
                    allowAdjacentInitialCount: allowAdjacentStartupCandidate
                )
                self.logInferredTransientRestoreDecision(
                    inferredRestoreDecision,
                    source: "Session monitoring"
                )
                if inferredRestoreDecision.shouldIgnore {
                    let transactionChangeCounts = inferredRestoreDecision.transactionChangeCounts
                    self.globalHistoryQueue.sync(flags: .barrier) {
                        self.removeInferredTransientTransactionFromGlobalHistory(transactionChangeCounts)
                    }
                    self.excludeInferredTransientTransactionFromSessions(transactionChangeCounts)
                    self.noteRecentClipboardActivity(
                        for: recordingPath,
                        changeCount: currentChangeCount,
                        timestamp: now,
                        lastCapturedClipboardContent: currentClipboard,
                        lastCapturedClipboardPayload: pasteboardSnapshot.payload
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                        self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
                    }
                    return
                }

                // Track ANY clipboard operation (even if content is identical) as changeCount indicates a copy action occurred
                // Store the app info with the change so we know which app made it
                let change = ClipboardChange(
                    content: currentClipboard,
                    payload: pasteboardSnapshot.payload,
                    timestamp: now,
                    changeCount: currentChangeCount,
                    frontAppName: appName.isEmpty ? nil : appName,
                    frontAppBundleId: bundleId.isEmpty ? nil : bundleId,
                    pasteboardTypes: pasteboardSnapshot.types.map(\.rawValue).sorted(),
                    isSameContentRewrite: isSameContentRewrite
                )
                
                // Always track the change, but only log routine captures while an action is executing.
                // Multiple samplers can observe the same changeCount; merge them idempotently so a
                // later non-nil payload repairs an incomplete first sample without creating a duplicate.
                sessionsQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self,
                          var session = self.earlyMonitoringSessions[recordingPath],
                          session.isActive,
                          shouldIncludeClipboardChange(
                              timestamp: change.timestamp,
                              resetAt: session.clipboardContextResetAt
                          ),
                          !self.isInferredTransientChangeCountIgnored(change.changeCount) else {
                        return
                    }

                    let mergeDecision = self.mergeClipboardChange(change, into: &session)
                    self.earlyMonitoringSessions[recordingPath] = session
                    if mergeDecision == .upgradeMissingContent {
                        logDebug(
                            "[ClipboardMonitor] Session monitoring upgraded missing clipboard content " +
                            "for changeCount \(currentChangeCount)"
                        )
                    }

                    // Only log if we're currently executing an action
                    if session.isExecutingAction {
                        logDebug("[ClipboardMonitor] Detected clipboard change during action execution (changeCount: \(currentChangeCount))")
                    }
                    if mergeDecision != .keepExisting,
                       change.payload.retainedImageByteCount > 0 {
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            self?.enforceMonitorWideImageRetentionBudget()
                        }
                    }
                }
            } else if shouldIgnoreAppFlag {
                self.cancelInferredTransientRestoreCandidate(
                    boundaryChangeCount: currentChangeCount,
                    observedAt: now
                )
                // RETROACTIVE CLEANUP: When an ignored app becomes frontmost and triggers clipboard changes,
                // check if there were recent clipboard changes that might have actually been caused by this
                // ignored app before it gained focus (e.g., during window activation).
                sessionsQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self,
                          var session = self.earlyMonitoringSessions[recordingPath],
                          session.isActive else {
                        return
                    }
                    
                    // Look for recent changes within the retroactive cleanup window
                    let retroactiveCleanupCutoff = now.addingTimeInterval(-RETROACTIVE_CLEANUP_WINDOW)
                    let recentChanges = session.clipboardChanges.filter { change in
                        change.timestamp >= retroactiveCleanupCutoff
                    }
                    
                    if !recentChanges.isEmpty {
                        // Remove these recent changes as they were likely caused by the ignored app
                        // during its activation before it became frontmost
                        let beforeCount = session.clipboardChanges.count
                        session.clipboardChanges.removeAll { change in
                            change.timestamp >= retroactiveCleanupCutoff
                        }
                        let removedCount = beforeCount - session.clipboardChanges.count
                        
                        if removedCount > 0 {
                            let removedAppNames = recentChanges.compactMap { $0.frontAppName }.joined(separator: ", ")
                            logDebug("[ClipboardMonitor] Session retroactive cleanup: Removed \(removedCount) recent clipboard change(s) attributed to '\(removedAppNames)' (likely caused by '\(appName)' during window activation)")
                        }
                    }
                    
                    session.lastSeenChangeCount = currentChangeCount
                    self.earlyMonitoringSessions[recordingPath] = session
                }
            } else {
                // Update the session's last seen change count (fallback case)
                sessionsQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self,
                          var session = self.earlyMonitoringSessions[recordingPath],
                          session.isActive else {
                        return
                    }
                    
                    session.lastSeenChangeCount = currentChangeCount
                    self.earlyMonitoringSessions[recordingPath] = session
                }
            }
        }
        
        // A slow provider can complete the same copy after our first poll.
        // Repair only a previously accepted observation, preserving its time
        // and app attribution; never turn a baseline/ignored copy into context.
        if currentChangeCount == sessionData.lastSeenChangeCount,
           clipboardAttachmentsEnabled,
           pasteboardSnapshot.payload.retainedImageByteCount > 0,
           ignoredMarkerType(in: pasteboardSnapshot.types) == nil,
           !shouldSuppressClipboardCapture(content: currentClipboard, payload: pasteboardSnapshot.payload, now: Date()) {
            sessionsQueue.async(flags: .barrier) { [weak self] in
                guard let self,
                      var session = self.earlyMonitoringSessions[recordingPath],
                      session.isActive,
                      session.lastSeenChangeCount == currentChangeCount,
                      let existing = session.clipboardChanges.first(where: { $0.changeCount == currentChangeCount }),
                      shouldIncludeClipboardChange(timestamp: existing.timestamp, resetAt: session.clipboardContextResetAt),
                      !self.isInferredTransientChangeCountIgnored(currentChangeCount),
                      let upgraded = self.upgradedClipboardImageChange(existing, snapshot: pasteboardSnapshot) else { return }
                self.mergeClipboardChange(upgraded, into: &session)
                self.earlyMonitoringSessions[recordingPath] = session
                logDebug("[ClipboardMonitor] Session monitoring resolved late image data (changeCount: \(currentChangeCount))")
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.enforceMonitorWideImageRetentionBudget()
                }
            }
        }

        // Continue monitoring as long as session exists
        // Session cleanup happens naturally when recording is processed
        var shouldContinue = false
        sessionsQueue.sync { [weak self] in
            shouldContinue = self?.earlyMonitoringSessions[recordingPath]?.isActive ?? false
        }
        
        if shouldContinue {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
        }
    }
    
    /// Executes an insert action with enhanced clipboard monitoring that uses early monitoring data
    /// - Parameters:
    ///   - insertAction: The closure that executes the actual insert action
    ///   - actionDelay: The user-configured action delay
    ///   - shouldEsc: Whether ESC should be simulated
    ///   - isAutoPaste: Whether this is an autoPaste action (affects ESC simulation logic)
    ///   - recordingPath: The recording path to use early monitoring data from
    ///   - metaJson: The meta.json data to extract swResult from
    ///   - restoreClipboard: Whether clipboard restoration should be performed
    func executeInsertWithEnhancedClipboardSync(
        insertAction: @escaping () -> Bool,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool = false,
        recordingPath: String,
        metaJson: [String: Any],
        restoreClipboard: Bool = true,
        shouldUseSuperwhisperSync: Bool = true,
        shouldStopMonitoringAfterAction: Bool = true,
        shouldTriggerCleanupAfterAction: Bool = true,
        restoreClipboardIndependentlyOfEsc: Bool = false,
        restoreClipboardDelay: TimeInterval = DEFAULT_CLIPBOARD_RESTORE_DELAY,
        forceEscForAutoPasteWhenNotInInputField: Bool = false,
        forceEscForEmptyInsert: Bool = false,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Determine if ESC will actually be simulated
            var escWillBeSimulated = false
            var userIsInInputField = false
            
            if shouldEsc {
                if isAutoPaste {
                    // For autoPaste, check once if user is in input field and cache the result
                    if requestAccessibilityPermission() {
                        userIsInInputField = isInInputField()
                        escWillBeSimulated = userIsInInputField || forceEscForAutoPasteWhenNotInInputField
                    }
                } else {
                    // For regular inserts, always simulate ESC if enabled
                    escWillBeSimulated = true
                }
            }
            if forceEscForEmptyInsert && shouldEsc {
                escWillBeSimulated = true
            }
            
            let shouldRestoreClipboard = restoreClipboardIndependentlyOfEsc
                ? restoreClipboard
                : (escWillBeSimulated && restoreClipboard)

            // Step 1: Mark action execution as starting (enables relevant clipboard logging)
            self.startActionExecution(for: recordingPath)

            // Step 2: Use Superwhisper clipboard synchronization only when requested (first chain action).
            self.withSuperwhisperClipboardSync(
                recordingPath: recordingPath,
                shouldUseSuperwhisperSync: shouldUseSuperwhisperSync
            ) { _ in
                self.proceedWithActionAndDelay(
                    insertAction: insertAction,
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: isAutoPaste,
                    userIsInInputField: userIsInInputField,
                    recordingPath: recordingPath,
                    shouldRestoreClipboard: shouldRestoreClipboard,
                    restoreDelay: restoreClipboardDelay,
                    shouldStopMonitoringAfterAction: shouldStopMonitoringAfterAction,
                    shouldTriggerCleanupAfterAction: shouldTriggerCleanupAfterAction,
                    forceEscForAutoPasteWhenNotInInputField: forceEscForAutoPasteWhenNotInInputField,
                    forceEscForEmptyInsert: forceEscForEmptyInsert,
                    onCompletion: onCompletion
                )
            }
        }
    }

    private func withSuperwhisperClipboardSync(
        recordingPath: String,
        shouldUseSuperwhisperSync: Bool,
        onReady: @escaping (Bool) -> Void
    ) {
        guard shouldUseSuperwhisperSync else {
            onReady(false)
            return
        }

        if hadRecentSessionClipboardActivity(for: recordingPath, within: recentClipboardActivityWindow) {
            logDebug("[ClipboardMonitor] Skipping wait: recent session clipboard activity detected near execution")
            onReady(true)
            return
        }

        logDebug("[ClipboardMonitor] Waiting for clipboard activity (maxWaitTime: \(maxWaitTime)s)")
        let startChangeCount = NSPasteboard.general.changeCount
        waitForSuperwhisperClipboardSync(startChangeCount: startChangeCount, onReady: onReady)
    }

    private func waitForSuperwhisperClipboardSync(
        startChangeCount: Int,
        onReady: @escaping (Bool) -> Void
    ) {
        pollForSuperwhisperClipboardSync(
            startTime: Date(),
            startChangeCount: startChangeCount,
            onReady: onReady
        )
    }

    private func pollForSuperwhisperClipboardSync(
        startTime: Date,
        startChangeCount: Int,
        onReady: @escaping (Bool) -> Void
    ) {
        let currentChangeCount = NSPasteboard.general.changeCount
        if currentChangeCount != startChangeCount {
            let elapsedMilliseconds = Int(max(0, Date().timeIntervalSince(startTime)) * 1_000)
            logDebug(
                "[ClipboardMonitor] Detected clipboard activity during Superwhisper synchronization polling " +
                "(elapsedMs: \(elapsedMilliseconds))"
            )
            onReady(false)
            return
        }

        if Date().timeIntervalSince(startTime) >= maxWaitTime {
            let elapsedMilliseconds = Int(max(0, Date().timeIntervalSince(startTime)) * 1_000)
            logDebug(
                "[ClipboardMonitor] Superwhisper synchronization polling reached its deadline; proceeding " +
                "(elapsedMs: \(elapsedMilliseconds), maxWaitMs: \(Int(maxWaitTime * 1_000)))"
            )
            onReady(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.pollForSuperwhisperClipboardSync(
                startTime: startTime,
                startChangeCount: startChangeCount,
                onReady: onReady
            )
        }
    }

    /// Returns true when the session captured clipboard activity very recently.
    /// This allows skipping the short Superwhisper wait even when clipboard text differs from swResult.
    private func hadRecentSessionClipboardActivity(for recordingPath: String, within window: TimeInterval) -> Bool {
        var hasRecentActivity = false
        let cutoff = Date().addingTimeInterval(-window)
        sessionsQueue.sync {
            guard let session = earlyMonitoringSessions[recordingPath] else { return }
            hasRecentActivity = (session.lastObservedClipboardActivityAt.map { $0 >= cutoff } ?? false)
                || session.clipboardChanges.contains { $0.timestamp >= cutoff }
        }
        return hasRecentActivity
    }

    /// Proceeds with action execution: applies actionDelay, simulates ESC, executes action, restores clipboard
    private func proceedWithActionAndDelay(
        insertAction: @escaping () -> Bool,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool,
        userIsInInputField: Bool,
        recordingPath: String,
        shouldRestoreClipboard: Bool,
        restoreDelay: TimeInterval,
        shouldStopMonitoringAfterAction: Bool,
        shouldTriggerCleanupAfterAction: Bool,
        forceEscForAutoPasteWhenNotInInputField: Bool,
        forceEscForEmptyInsert: Bool,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        // Step 1: Apply actionDelay now that clipboard synchronization is complete
        if actionDelay > 0 {
            Thread.sleep(forTimeInterval: actionDelay)
            logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s after clipboard sync")
        }
        
        // Step 2: Simulate ESC after actionDelay if enabled
        if shouldEsc {
            if isAutoPaste {
                // For autoPaste, use the cached input field status
                if !requestAccessibilityPermission() {
                    logWarning("[ClipboardMonitor] Accessibility permission denied for autoPaste input field check")
                } else if userIsInInputField {
                    simulateKeyDown(key: 53) // ESC key
                    logDebug("[ClipboardMonitor] ESC key pressed for autoPaste (user is in input field)")
                } else if forceEscForAutoPasteWhenNotInInputField {
                    simulateKeyDown(key: 53) // ESC key
                    logDebug("[ClipboardMonitor] ESC key pressed for autoPaste chain continuation (user not in input field)")
                } else {
                    logDebug("[ClipboardMonitor] ESC key skipped for autoPaste (user not in input field)")
                }
            } else {
                // For regular inserts, always simulate ESC if enabled
                simulateKeyDown(key: 53) // ESC key
                logDebug("[ClipboardMonitor] ESC key pressed for responsiveness")
            }
        }
        // Step 3: Execute the insert action
        let didSucceed = insertAction()
        self.markClipboardChainStepResult(for: recordingPath, succeeded: didSucceed)
        
        // Step 4: Mark action execution as finished (disables clipboard change logging)
        let cleanupDelay = shouldRestoreClipboard
            ? max(0, restoreDelay + CLIPBOARD_CLEANUP_GRACE)
            : CLIPBOARD_CLEANUP_GRACE
        self.finishActionExecution(
            for: recordingPath,
            shouldCleanup: shouldTriggerCleanupAfterAction,
            cleanupDelay: cleanupDelay
        )
        self.markGroupRestoreIntent(
            for: recordingPath,
            shouldRestoreClipboard: shouldRestoreClipboard,
            restoreDelay: restoreDelay
        )

        // Step 5: Restore clipboard only when requested; stop monitoring only at end of chain.
        let completion = onCompletion
        if shouldStopMonitoringAfterAction {
            self.stopEarlyMonitoring(for: recordingPath) {
                completion?(didSucceed)
            }
        } else {
            completion?(didSucceed)
        }
        
        logDebug(
            "[ClipboardMonitor] Action clipboard handling completed " +
            "(succeeded: \(didSucceed), restoreScheduled: \(shouldRestoreClipboard), finalStep: \(shouldStopMonitoringAfterAction))"
        )
    }
    
    private func payloadForSuppression(_ snapshot: ClipboardOriginalSnapshot?) -> ClipboardPayload? {
        guard let snapshot else { return nil }
        let items = snapshot.items.compactMap { item -> ClipboardPayloadItem? in
            // Match capture-time strongest-representation classification so
            // the restoration write's suppression fingerprint equals the
            // payload the monitor will observe on the pasteboard.
            if let fileURL = item.representations.compactMap({ representation -> URL? in
                if case .fileURL(let url) = representation, url.isFileURL { return url }
                return nil
            }).first {
                return .fileURL(fileURL)
            }
            if let png = item.representations.compactMap({ representation -> Data? in
                if case .png(let data) = representation { return data }
                return nil
            }).first {
                return .imagePNG(png)
            }
            if let tiff = item.representations.compactMap({ representation -> Data? in
                if case .tiff(let data) = representation { return data }
                return nil
            }).first {
                return .imageTIFF(tiff)
            }
            return item.representations.compactMap { representation -> String? in
                if case .text(let text) = representation { return text }
                return nil
            }.first.map(ClipboardPayloadItem.text)
        }
        return ClipboardPayload(items: items, legacyText: snapshot.legacyText)
    }

    /// Restores all supported representations captured at recording start.
    private func restoreCorrectClipboard(_ snapshot: ClipboardOriginalSnapshot?) {
        guard let snapshot else {
            logDebug(
                "[ClipboardMonitor] Original clipboard restoration skipped " +
                "(reason: unstable-or-unavailable-session-start-snapshot)"
            )
            return
        }
        if !snapshot.isComplete {
            logDebug(
                "[ClipboardMonitor] Original clipboard restoration skipped " +
                "(reason: unavailable-attachment, omittedAttachments: \(snapshot.omittedAttachmentCount))"
            )
            return
        }
        if let payload = payloadForSuppression(snapshot) {
            suppressNextClipboardCapture(for: payload, duration: 1.5)
        }
        guard writeClipboardOriginalSnapshot(snapshot) else {
            logWarning("[ClipboardMonitor] Failed to write the supported original clipboard snapshot")
            return
        }
        if snapshot.isEmpty {
            logDebug("[ClipboardMonitor] Cleared clipboard (session-start clipboard was empty)")
        } else {
            logDebug(
                "[ClipboardMonitor] Restored original clipboard snapshot " +
                "(items: \(snapshot.items.count), retainedImageBytes: \(snapshot.retainedImageByteCount))"
            )
        }
    }

    /// Stable, representation-aware original snapshot for CLI or alternate
    /// consumers. This API never reads file contents.
    func captureOriginalClipboardSnapshot() -> ClipboardOriginalSnapshot? {
        let originalCaptureLimits = limitsForNewOriginalSnapshot()
        return captureClipboardPasteboardSnapshot(
            from: .general,
            source: "original-capture",
            includeAttachments: true,
            captureOriginalSnapshot: true,
            attachmentLimits: originalCaptureLimits
        )?.originalSnapshot
    }

    @discardableResult
    func restoreOriginalClipboardSnapshot(_ snapshot: ClipboardOriginalSnapshot?) -> Bool {
        guard let snapshot else {
            logDebug(
                "[ClipboardMonitor] External original clipboard restoration skipped " +
                "(reason: unstable-or-unavailable-snapshot)"
            )
            return false
        }
        guard snapshot.isComplete else {
            logDebug(
                "[ClipboardMonitor] External original clipboard restoration skipped " +
                "(reason: unavailable-attachment, omittedAttachments: \(snapshot.omittedAttachmentCount))"
            )
            return false
        }
        if let payload = payloadForSuppression(snapshot) {
            suppressNextClipboardCapture(for: payload, duration: 1.5)
        }
        return writeClipboardOriginalSnapshot(snapshot)
    }
    
    /// Executes a non-insert action with clipboard restoration if ESC is simulated
    /// This handles URL, Shortcut, Shell Script, and AppleScript actions
    /// - Parameters:
    ///   - action: The closure that executes the actual action
    ///   - shouldEsc: Whether ESC should be simulated
    ///   - actionDelay: The action delay to apply
    ///   - recordingPath: The recording path for early monitoring data
    ///   - restoreClipboard: Whether clipboard restoration is enabled in settings
    func executeNonInsertActionWithClipboardRestore(
        action: @escaping () -> Bool,
        shouldEsc: Bool,
        actionDelay: TimeInterval,
        recordingPath: String,
        restoreClipboard: Bool = true,
        shouldUseSuperwhisperSync: Bool = true,
        shouldStopMonitoringAfterAction: Bool = true,
        shouldTriggerCleanupAfterAction: Bool = true,
        restoreClipboardIndependentlyOfEsc: Bool = false,
        restoreClipboardDelay: TimeInterval = DEFAULT_CLIPBOARD_RESTORE_DELAY,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let shouldRestoreClipboard = restoreClipboardIndependentlyOfEsc
                ? restoreClipboard
                : (shouldEsc && restoreClipboard)
            
            // Mark action execution as starting
            self.startActionExecution(for: recordingPath)

            self.withSuperwhisperClipboardSync(
                recordingPath: recordingPath,
                shouldUseSuperwhisperSync: shouldUseSuperwhisperSync
            ) { _ in
                // Apply actionDelay after clipboard synchronization.
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s after clipboard sync (non-insert with restore)")
                }
                
                // Simulate ESC after actionDelay if requested
                if shouldEsc {
                    simulateKeyDown(key: 53) // ESC key
                    logDebug("[ClipboardMonitor] ESC key pressed for non-insert action with restore")
                }
                
                // Execute the action
                let didSucceed = action()
                self.markClipboardChainStepResult(for: recordingPath, succeeded: didSucceed)
                
                // Mark action execution as finished
                let cleanupDelay = shouldRestoreClipboard
                    ? max(0, restoreClipboardDelay + CLIPBOARD_CLEANUP_GRACE)
                    : CLIPBOARD_CLEANUP_GRACE
                self.finishActionExecution(
                    for: recordingPath,
                    shouldCleanup: shouldTriggerCleanupAfterAction,
                    cleanupDelay: cleanupDelay
                )
                self.markGroupRestoreIntent(
                    for: recordingPath,
                    shouldRestoreClipboard: shouldRestoreClipboard,
                    restoreDelay: restoreClipboardDelay
                )

                let completion = onCompletion
                if shouldStopMonitoringAfterAction {
                    self.stopEarlyMonitoring(for: recordingPath) {
                        completion?(didSucceed)
                    }
                } else {
                    completion?(didSucceed)
                }
                
                logDebug(
                    "[ClipboardMonitor] Action clipboard handling completed " +
                    "(succeeded: \(didSucceed), restoreScheduled: \(shouldRestoreClipboard), finalStep: \(shouldStopMonitoringAfterAction))"
                )
            }
        }
    }
    
    // MARK: - Global Clipboard Monitoring (Lightweight App-Lifetime)
    
    /// Starts lightweight global clipboard monitoring to maintain 5-second rolling buffer
    /// This ensures pre-recording clipboard content is available even for the first recording session
    private func startGlobalClipboardMonitoring() {
        // Prevent multiple timers from being created
        guard globalMonitoringTimer == nil else {
            logDebug("[ClipboardMonitor] Global monitoring already running, skipping start")
            return
        }
        
        logDebug("[ClipboardMonitor] Starting lightweight global clipboard monitoring")
        
        // Initialize with empty history - we only want to track actual clipboard CHANGES
        // Don't timestamp existing clipboard content as "new" since we don't know when it was actually copied
        globalHistoryQueue.async(flags: .barrier) { [weak self] in
            self?.globalClipboardHistory = []
            self?.lastSeenClipboardContent = nil
            self?.lastSeenClipboardPayload = nil
            self?.lastSeenChangeCount = 0
            self?.lastSeenClipboardChangeObservedAt = nil
            self?.isFirstGlobalCheck = true
        }
        
        // Start periodic monitoring with 0.5s interval (lightweight)
        DispatchQueue.main.async { [weak self] in
            self?.globalMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkGlobalClipboardChange()
            }
            if let timer = self?.globalMonitoringTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    
    /// Stops global clipboard monitoring
    private func stopGlobalClipboardMonitoring() {
        globalMonitoringTimer?.invalidate()
        globalMonitoringTimer = nil

        var hasActiveSession = false
        sessionsQueue.sync {
            hasActiveSession = earlyMonitoringSessions.values.contains { $0.isActive }
        }
        globalHistoryQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.globalClipboardHistory.removeAll()
            self.lastSeenClipboardContent = nil
            self.lastSeenClipboardPayload = nil
            self.lastSeenChangeCount = 0
            self.lastSeenClipboardChangeObservedAt = nil
            self.isFirstGlobalCheck = true
            if !hasActiveSession {
                self.resetIgnoredClipboardSequenceTrackers()
            }
        }
        
        logDebug("[ClipboardMonitor] Stopped global clipboard monitoring")
    }

    // MARK: - Public Configuration Update
    /// Updates the pre-recording clipboard buffer window (in seconds). 0 disables global buffer.
    func updateClipboardBuffer(seconds: TimeInterval) {
        let newValue = max(0.0, seconds)
        if newValue == preRecordingBuffer { return }

        preRecordingBuffer = newValue
        if newValue == 0 {
            stopGlobalClipboardMonitoring()
            logInfo("[ClipboardMonitor] Disabled global clipboard buffer (clipboardBuffer = 0)")
        } else {
            // Restart monitoring to apply new window; history is lightweight and will refill
            stopGlobalClipboardMonitoring()
            startGlobalClipboardMonitoring()
            logInfo(String(format: "[ClipboardMonitor] Updated global clipboard buffer to %.2fs", newValue))
        }
        
        // Restart cleanup timer with new interval based on updated buffer setting
        stopPeriodicCleanup()
        startPeriodicCleanup()
    }
    
    /// Updates the clipboard ignore pattern for filtering clipboard content from specific apps
    /// - Parameter pattern: Regex pattern matching app names or bundle IDs (pipe-separated)
    func updateClipboardIgnore(pattern: String) {
        clipboardIgnorePattern = pattern
        if pattern.isEmpty {
            logInfo("[ClipboardMonitor] Cleared clipboard ignore pattern - all apps will be monitored")
        } else {
            logInfo("[ClipboardMonitor] Updated clipboard ignore pattern: '\(pattern)'")
        }
    }
    
    /// Checks if the frontmost application should be ignored based on clipboardIgnore pattern
    /// Returns true if the app matches the ignore pattern, false otherwise
    private func shouldIgnoreFrontmostApp() -> Bool {
        let frontApp = resolveFrontAppIdentity()
        guard let app = frontApp else { return false }
        
        // Get app name and bundle ID for matching
        let appName = app.localizedName ?? ""
        let bundleId = app.bundleIdentifier ?? ""
        
        return shouldIgnoreApp(appName: appName, bundleId: bundleId)
    }
    
    /// Checks if an application should be ignored based on clipboardIgnore pattern
    /// - Parameters:
    ///   - appName: The name of the application
    ///   - bundleId: The bundle identifier of the application
    /// - Returns: true if the app matches the ignore pattern, false otherwise
    private func shouldIgnoreApp(appName: String, bundleId: String) -> Bool {
        // If no ignore pattern is set, don't ignore any apps
        guard !clipboardIgnorePattern.isEmpty else { return false }
        
        // Try to match against the ignore pattern (supports regex with pipe-separated values)
        do {
            let regex = try NSRegularExpression(pattern: clipboardIgnorePattern, options: [.caseInsensitive])
            
            // Check if app name matches
            let nameRange = NSRange(appName.startIndex..., in: appName)
            if regex.firstMatch(in: appName, options: [], range: nameRange) != nil {
                logDebug("[ClipboardMonitor] Ignoring clipboard change from app '\(appName)' (matched by name)")
                return true
            }
            
            // Check if bundle ID matches
            let bundleRange = NSRange(bundleId.startIndex..., in: bundleId)
            if regex.firstMatch(in: bundleId, options: [], range: bundleRange) != nil {
                logDebug("[ClipboardMonitor] Ignoring clipboard change from app '\(appName)' (\(bundleId)) (matched by bundle ID)")
                return true
            }
        } catch {
            logError("[ClipboardMonitor] Invalid clipboardIgnore regex pattern '\(clipboardIgnorePattern)': \(error.localizedDescription)")
        }
        
        return false
    }

    /// Removes observations that may have been attributed before ignored activity became visible.
    /// Must be called while holding the global-history barrier.
    private func performGlobalRetroactiveCleanup(now: Date, appName: String) {
        let retroactiveCleanupCutoff = now.addingTimeInterval(-RETROACTIVE_CLEANUP_WINDOW)
        let recentChanges = globalClipboardHistory.filter { change in
            change.timestamp >= retroactiveCleanupCutoff
        }
        guard !recentChanges.isEmpty else { return }

        let beforeCount = globalClipboardHistory.count
        globalClipboardHistory.removeAll { change in
            change.timestamp >= retroactiveCleanupCutoff
        }
        let removedCount = beforeCount - globalClipboardHistory.count
        guard removedCount > 0 else { return }

        let removedAppNames = recentChanges.compactMap { $0.frontAppName }.joined(separator: ", ")
        logDebug(
            "[ClipboardMonitor] Retroactive cleanup: Removed \(removedCount) recent clipboard " +
            "change(s) attributed to '\(removedAppNames)' (likely caused by '\(appName)' during window activation)"
        )
    }

    private func ignoredMarkerType(
        in types: [NSPasteboard.PasteboardType]
    ) -> NSPasteboard.PasteboardType? {
        for markerType in TRANSIENT_MARKER_TYPES {
            if types.contains(markerType) {
                return markerType
            }
        }

        for markerType in CONCEALED_MARKER_TYPES {
            if types.contains(markerType) {
                return markerType
            }
        }
        return nil
    }

    private func ignoredMarkerSequenceDecision(
        changeCount: Int,
        containsIgnoredMarker: Bool,
        observedAt: Date
    ) -> IgnoredClipboardMarkerSequenceDecision {
        ignoredMarkerSequenceQueue.sync {
            ignoredMarkerSequenceTracker.decision(
                changeCount: changeCount,
                containsIgnoredMarker: containsIgnoredMarker,
                observedAt: observedAt
            )
        }
    }

    private func inferredTransientRestoreDecision(
        changeCount: Int,
        content: String?,
        payload: ClipboardPayload? = nil,
        containsIgnoredMarker: Bool,
        observedAt: Date,
        previousChangeCount: Int,
        previousContent: String?,
        previousPayload: ClipboardPayload? = nil,
        restoreWindow: TimeInterval = INFERRED_TRANSIENT_RESTORE_WINDOW,
        canArmCandidate: Bool = true,
        allowAdjacentInitialCount: Bool = false
    ) -> InferredTransientRestoreDecision {
        ignoredMarkerSequenceQueue.sync {
            inferredTransientRestoreTracker.decision(
                changeCount: changeCount,
                content: content,
                containsIgnoredMarker: containsIgnoredMarker,
                observedAt: observedAt,
                previousChangeCount: previousChangeCount,
                previousContent: previousContent,
                payloadFingerprint: payload?.fingerprint,
                previousPayloadFingerprint: previousPayload?.fingerprint,
                restoreWindow: restoreWindow,
                canArmCandidate: canArmCandidate,
                allowAdjacentInitialCount: allowAdjacentInitialCount
            )
        }
    }

    private func allowsAdjacentStartupTransientCandidate(
        for recordingPath: String?,
        changeCount: Int,
        observedAt: Date
    ) -> Bool {
        var shouldAllow = false
        sessionsQueue.sync {
            shouldAllow = earlyMonitoringSessions.contains { path, session in
                guard session.isActive,
                      recordingPath == nil || path == recordingPath,
                      let group = executionGroups[session.groupId],
                      group.rootRecordingPath == path else {
                    return false
                }

                return shouldAllowAdjacentStartupTransientCandidate(
                    sessionStartInputFieldState: session.sessionStartInputFieldState,
                    sessionStartTime: session.startTime,
                    startupReplayGuardEndsAt: session.startupReplayGuardEndsAt,
                    startingChangeCount: session.startingChangeCount,
                    changeCount: changeCount,
                    observedAt: observedAt
                )
            }
        }
        return shouldAllow
    }

    /// Reconciles the narrow bootstrap race where the session-start snapshot
    /// catches Superwhisper's temporary clipboard and the first visible session
    /// operation restores the previously stable clipboard. This performs no
    /// waiting and only re-reads the pasteboard after the exact transaction has
    /// already matched.
    private func reconcileStartupClipboardBootstrapRestore(
        for recordingPath: String,
        observedSnapshot: ClipboardPasteboardSnapshot,
        observedAt: Date
    ) -> Bool {
        var state: StartupClipboardBootstrapState?
        var inputFieldState: SessionStartInputFieldState = .unknown
        var sessionStartTime = observedAt
        var targetGroupId: String?
        sessionsQueue.sync {
            guard let session = earlyMonitoringSessions[recordingPath], session.isActive else { return }
            state = session.startupBootstrapState
            inputFieldState = session.sessionStartInputFieldState
            sessionStartTime = session.startTime
            targetGroupId = session.groupId
        }

        var globalRestoreOperationObservedAt: Date?
        globalHistoryQueue.sync {
            if lastSeenChangeCount == observedSnapshot.changeCount,
               lastSeenClipboardPayload?.fingerprint == observedSnapshot.payload.fingerprint {
                globalRestoreOperationObservedAt = lastSeenClipboardChangeObservedAt
            } else if let globalObservation = globalClipboardHistory.last(where: {
                $0.changeCount == observedSnapshot.changeCount
            }), globalObservation.payload.fingerprint == observedSnapshot.payload.fingerprint {
                globalRestoreOperationObservedAt = globalObservation.timestamp
            }
        }

        // Prefer the global operation timestamp because it remains accurate if
        // Accessibility work delays the session poll. If the 10 ms session
        // sampler reaches the restoration before the 500 ms global sampler,
        // its own timely observation is sufficient and avoids adding a wait.
        let candidateObservationTimes: [(source: String, observedAt: Date)] = {
            var values: [(String, Date)] = []
            if let globalRestoreOperationObservedAt {
                values.append(("global", globalRestoreOperationObservedAt))
            }
            values.append(("session", observedAt))
            return values
        }()
        guard let matchedObservation = candidateObservationTimes.first(where: { candidate in
            evaluateStartupClipboardBootstrapRestore(
                state: state,
                sessionStartInputFieldState: inputFieldState,
                sessionStartTime: sessionStartTime,
                observedAt: candidate.observedAt,
                observedChangeCount: observedSnapshot.changeCount,
                observedPayloadFingerprint: observedSnapshot.payload.fingerprint
            ) == .ignoreRestoredStableClipboard
        }), let state else {
            return false
        }
        let decision = StartupClipboardBootstrapRestoreDecision.ignoreRestoredStableClipboard
        let restoreOperationObservedAt = matchedObservation.observedAt

        // Capture the restored X state representation-faithfully only after the
        // pure count/fingerprint classifier has matched X -> Y -> X. This keeps
        // ordinary recording startup on the existing fast path.
        guard let correctedSnapshot = captureClipboardPasteboardSnapshot(
            from: .general,
            source: "startup-bootstrap-reconcile",
            includeAttachments: true,
            captureOriginalSnapshot: true,
            attachmentLimits: limitsForNewOriginalSnapshot(
                replacingOriginalForGroupId: targetGroupId
            )
        ), correctedSnapshot.changeCount == observedSnapshot.changeCount else {
            logDebug(
                "[ClipboardMonitor] Startup clipboard bootstrap reconciliation deferred " +
                "(reason: clipboard-changed-during-snapshot, stableChangeCount: \(state.stableGlobalChangeCount), " +
                "sessionChangeCount: \(state.sessionSnapshotChangeCount), " +
                "observedChangeCount: \(observedSnapshot.changeCount))"
            )
            return false
        }

        let transactionChangeCounts: Set<Int> = [
            state.sessionSnapshotChangeCount,
            observedSnapshot.changeCount
        ]
        var didReconcile = false
        globalHistoryQueue.sync(flags: .barrier) {
            sessionsQueue.sync(flags: .barrier) {
                guard var session = earlyMonitoringSessions[recordingPath],
                      session.isActive,
                      session.startupBootstrapState == state,
                      let groupId = recordingPathToGroupId[recordingPath],
                      var group = executionGroups[groupId],
                      group.rootRecordingPath == recordingPath else {
                    return
                }

                session.startupBootstrapState = nil
                session.ignoredClipboardChangeCounts.formUnion(transactionChangeCounts)
                session.clipboardChanges.removeAll { transactionChangeCounts.contains($0.changeCount) }
                session.lastSeenChangeCount = observedSnapshot.changeCount
                session.lastCapturedClipboardContent = observedSnapshot.content
                session.lastCapturedClipboardPayload = observedSnapshot.payload
                session.lastObservedClipboardActivityAt = restoreOperationObservedAt
                session.lastDiagnosticClipboardChangeObservedAt = observedAt
                earlyMonitoringSessions[recordingPath] = session

                group.rootOriginalSnapshot = correctedSnapshot.originalSnapshot
                executionGroups[groupId] = group
                globalClipboardHistory.removeAll { transactionChangeCounts.contains($0.changeCount) }
                ignoredMarkerSequenceQueue.sync {
                    inferredTransientRestoreTracker.recordIgnoredTransaction(
                        candidateChangeCount: state.sessionSnapshotChangeCount,
                        restoreChangeCount: observedSnapshot.changeCount,
                        classifiedAt: restoreOperationObservedAt
                    )
                }
                didReconcile = true
            }
        }
        guard didReconcile else { return false }
        enforceMonitorWideImageRetentionBudget()

        let operationElapsedMilliseconds = Int(
            max(0, restoreOperationObservedAt.timeIntervalSince(state.sessionSnapshotObservedAt)) * 1_000
        )
        let pollElapsedMilliseconds = Int(max(0, observedAt.timeIntervalSince(sessionStartTime)) * 1_000)
        let stableBaselineAgeMilliseconds = state.stableGlobalLastChangeObservedAt.map {
            Int(max(0, state.sessionSnapshotObservedAt.timeIntervalSince($0)) * 1_000)
        }
        let stableBaselineAgeLogValue = stableBaselineAgeMilliseconds.map(String.init) ?? "unknown"
        let correctedOriginal = correctedSnapshot.originalSnapshot
        logDebug(
            "[ClipboardMonitor] Reconciled startup clipboard bootstrap restore " +
            "(decision: \(decision.rawValue), stableChangeCount: \(state.stableGlobalChangeCount), " +
            "temporaryChangeCount: \(state.sessionSnapshotChangeCount), " +
            "restoreChangeCount: \(observedSnapshot.changeCount), " +
            "timingSource: \(matchedObservation.source), operationElapsedMs: \(operationElapsedMilliseconds), " +
            "pollElapsedMs: \(pollElapsedMilliseconds), " +
            "stableBaselineAgeMs: \(stableBaselineAgeLogValue), " +
            "stableFingerprint: \(state.stableGlobalPayloadFingerprint), " +
            "temporaryFingerprint: \(state.sessionSnapshotPayloadFingerprint), " +
            "restoreFingerprint: \(observedSnapshot.payload.fingerprint), " +
            "restoreTypes: \(observedSnapshot.types.map(\.rawValue).sorted()), " +
            "originalSnapshotComplete: \(correctedOriginal?.isComplete ?? false), " +
            "omittedAttachments: \(correctedOriginal?.omittedAttachmentCount ?? 0))"
        )
        return true
    }

    private func isInferredTransientChangeCountIgnored(_ changeCount: Int) -> Bool {
        ignoredMarkerSequenceQueue.sync {
            inferredTransientRestoreTracker.isIgnored(changeCount: changeCount)
        }
    }

    private func cancelInferredTransientRestoreCandidate(
        boundaryChangeCount: Int,
        observedAt: Date
    ) {
        ignoredMarkerSequenceQueue.sync {
            inferredTransientRestoreTracker.cancelPendingCandidate(
                boundaryChangeCount: boundaryChangeCount,
                observedAt: observedAt
            )
        }
    }

    private func resetIgnoredClipboardSequenceTrackers() {
        ignoredMarkerSequenceQueue.sync {
            ignoredMarkerSequenceTracker.reset()
            inferredTransientRestoreTracker.reset()
        }
    }

    private func logMarkerSequenceDecision(
        _ decision: IgnoredClipboardMarkerSequenceDecision,
        markerType: NSPasteboard.PasteboardType?,
        changeCount: Int,
        source: String
    ) {
        switch decision {
        case .capture:
            logDebug(
                "[ClipboardMonitor] \(source) marker-sequence classification " +
                "(changeCount: \(changeCount), decision: \(decision.rawValue), marker: none)"
            )
        case .ignorePreviouslyClassified:
            let markerName = markerType?.rawValue ?? "none"
            logDebug(
                "[ClipboardMonitor] \(source) ignoring previously classified clipboard operation " +
                "(changeCount: \(changeCount), decision: \(decision.rawValue), marker: \(markerName))"
            )
        case .ignoreMarker:
            let markerName = markerType?.rawValue ?? "unknown"
            logDebug(
                "[ClipboardMonitor] \(source) ignoring marked clipboard operation " +
                "(changeCount: \(changeCount), decision: \(decision.rawValue), marker: \(markerName))"
            )
        case .ignoreFollowUp:
            logDebug(
                "[ClipboardMonitor] \(source) ignoring unmarked follow-up from a recent marked " +
                "clipboard operation (changeCount: \(changeCount), decision: \(decision.rawValue))"
            )
        }
    }

    private func logInferredTransientRestoreDecision(
        _ decision: InferredTransientRestoreDecision,
        source: String
    ) {
        switch decision {
        case .capture:
            break
        case .captureCandidate(let changeCount):
            logDebug(
                "[ClipboardMonitor] \(source) observed possible transient restore candidate " +
                "(changeCount: \(changeCount)); retaining it unless the next write promptly restores the prior clipboard"
            )
        case .ignoreTransaction(let candidateChangeCount, let restoreChangeCount):
            logDebug(
                "[ClipboardMonitor] \(source) inferred a rapid transient clipboard restore transaction " +
                "(temporary changeCount: \(candidateChangeCount), restore changeCount: \(restoreChangeCount)); " +
                "excluding both operations from clipboard context"
            )
        case .ignorePreviouslyClassified(let candidateChangeCount, let restoreChangeCount):
            logDebug(
                "[ClipboardMonitor] \(source) ignoring previously classified transient restore transaction " +
                "(temporary changeCount: \(candidateChangeCount), restore changeCount: \(restoreChangeCount))"
            )
        }
    }

    /// Removes the inferred transaction from global history. The caller must hold
    /// the global-history barrier so the candidate cannot race a context snapshot.
    private func removeInferredTransientTransactionFromGlobalHistory(_ changeCounts: Set<Int>) {
        let beforeCount = globalClipboardHistory.count
        globalClipboardHistory.removeAll { changeCounts.contains($0.changeCount) }
        let removedCount = beforeCount - globalClipboardHistory.count
        if removedCount > 0 {
            logDebug(
                "[ClipboardMonitor] Removed \(removedCount) inferred transient clipboard operation(s) from global history"
            )
        }
    }

    /// Removes cached pre-recording values by their change-count metadata while
    /// preserving identical, unrelated copies elsewhere in the stack.
    private func removeInferredTransientPreRecordingChanges(
        changeCounts: Set<Int>,
        changes: [ClipboardChange],
        stack: [String]
    ) -> (changes: [ClipboardChange], stack: [String], single: String?, removedCount: Int) {
        let removedChanges = changes.filter { changeCounts.contains($0.changeCount) }
        guard !removedChanges.isEmpty else {
            return (changes, stack, stack.last, 0)
        }

        var filteredStack = stack

        // Cached stack values follow change order. Remove from newest to oldest so
        // lastIndex selects the corresponding occurrence when values are repeated.
        for change in removedChanges.reversed() {
            guard let content = change.content else { continue }
            let normalized = sanitizeContextPlaceholderValue(content)
            guard !normalized.isEmpty,
                  let stackIndex = filteredStack.lastIndex(of: normalized) else {
                continue
            }
            filteredStack.remove(at: stackIndex)
        }

        let filteredChanges = changes.filter { !changeCounts.contains($0.changeCount) }
        return (filteredChanges, filteredStack, filteredStack.last, removedChanges.count)
    }

    /// Excludes the inferred transaction from every live context cache and marks
    /// both counts so delayed work from either sampler cannot reinsert them.
    private func excludeInferredTransientTransactionFromSessions(_ changeCounts: Set<Int>) {
        sessionsQueue.sync(flags: .barrier) {
            var removedSessionChanges = 0
            var removedPreRecordingChanges = 0

            for recordingPath in Array(earlyMonitoringSessions.keys) {
                guard var session = earlyMonitoringSessions[recordingPath] else { continue }
                session.ignoredClipboardChangeCounts.formUnion(changeCounts)

                let beforeCount = session.clipboardChanges.count
                session.clipboardChanges.removeAll { changeCounts.contains($0.changeCount) }
                removedSessionChanges += beforeCount - session.clipboardChanges.count

                let filteredPreRecording = removeInferredTransientPreRecordingChanges(
                    changeCounts: changeCounts,
                    changes: session.preRecordingChanges,
                    stack: session.preRecordingClipboardStack
                )
                session.preRecordingChanges = filteredPreRecording.changes
                session.preRecordingClipboardStack = filteredPreRecording.stack
                session.preRecordingClipboard = filteredPreRecording.single
                removedPreRecordingChanges += filteredPreRecording.removedCount
                earlyMonitoringSessions[recordingPath] = session
            }

            for groupId in Array(executionGroups.keys) {
                guard var group = executionGroups[groupId] else { continue }
                let filteredPreRecording = removeInferredTransientPreRecordingChanges(
                    changeCounts: changeCounts,
                    changes: group.rootPreRecordingChanges,
                    stack: group.rootPreRecordingClipboardStack
                )
                group.rootPreRecordingChanges = filteredPreRecording.changes
                group.rootPreRecordingClipboardStack = filteredPreRecording.stack
                group.rootPreRecordingClipboard = filteredPreRecording.single
                removedPreRecordingChanges += filteredPreRecording.removedCount
                executionGroups[groupId] = group
            }

            if removedSessionChanges > 0 || removedPreRecordingChanges > 0 {
                logDebug(
                    "[ClipboardMonitor] Removed inferred transient transaction from active context " +
                    "(session changes: \(removedSessionChanges), pre-recording changes: \(removedPreRecordingChanges))"
                )
            }
        }
    }

    private func noteRecentClipboardActivity(
        for recordingPath: String,
        changeCount: Int,
        timestamp: Date,
        lastCapturedClipboardContent: String? = nil,
        lastCapturedClipboardPayload: ClipboardPayload? = nil
    ) {
        sessionsQueue.sync(flags: .barrier) { [weak self] in
            guard let self,
                  var session = self.earlyMonitoringSessions[recordingPath],
                  session.isActive,
                  shouldIncludeClipboardChange(
                      timestamp: timestamp,
                      resetAt: session.clipboardContextResetAt
                  ) else {
                return
            }

            session.lastSeenChangeCount = changeCount
            session.lastObservedClipboardActivityAt = timestamp
            if let lastCapturedClipboardContent {
                session.lastCapturedClipboardContent = lastCapturedClipboardContent
            }
            if let lastCapturedClipboardPayload {
                session.lastCapturedClipboardPayload = lastCapturedClipboardPayload
            }
            self.earlyMonitoringSessions[recordingPath] = session
        }
    }
    
    /// Triggers clipboard cleanup for CLI actions that bypass the normal action execution flow
    /// This ensures CLI actions also get the full reset treatment to prevent contamination
    func triggerClipboardCleanupForCLI() {
        logDebug("[ClipboardMonitor] Triggering clipboard cleanup for CLI action execution")
        
        // Perform the same cleanup as finishActionExecution but without session-specific data
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // FULL RESET: Clear ALL global clipboard history to prevent contamination
            // This ensures that any content that was captured during CLI action execution
            // won't appear in future clipboardContext placeholders
            var cleanedGlobalEntries = 0
            self.globalHistoryQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                // FULL RESET: Remove ALL global history entries, not just the last 2 seconds
                let beforeCount = self.globalClipboardHistory.count
                self.globalClipboardHistory.removeAll()
                cleanedGlobalEntries = beforeCount
                
                // Reset the last seen content to prevent immediate re-capture of restored content
                self.lastSeenClipboardContent = nil
                self.lastSeenClipboardPayload = nil
                self.lastSeenChangeCount = 0
                self.lastSeenClipboardChangeObservedAt = nil
                self.isFirstGlobalCheck = true
                self.resetIgnoredClipboardSequenceTrackers()
                
                // Log cleanup details on main queue
                DispatchQueue.main.async {
                    if cleanedGlobalEntries > 0 {
                        logDebug("[ClipboardMonitor] CLI FULL RESET: Cleaned up \(cleanedGlobalEntries) global history entries after CLI action execution to prevent clipboardContext contamination")
                    }
                }
            }
            
            // RESET PERIODIC CLEANUP TIMER: Restart the periodic cleanup timer to start fresh
            // This ensures the periodic cleanup doesn't interfere with the CLI action execution cleanup
            DispatchQueue.main.async {
                self.stopPeriodicCleanup()
                self.startPeriodicCleanup()
                logDebug("[ClipboardMonitor] Reset periodic cleanup timer after CLI action execution")
            }
        }
    }

    /// Suppresses capture of the next CLI-origin clipboard write for a short window.
    /// This keeps clipboard content visible to other apps while preventing Macrowhisper self-capture.
    func suppressNextClipboardCapture(for content: String, duration: TimeInterval = 1.0) {
        let expiresAt = Date().addingTimeInterval(max(0.1, duration))
        cliSuppressionQueue.sync {
            suppressedCliClipboardContent = content
            suppressedCliClipboardFingerprint = nil
            suppressedCliClipboardUntil = expiresAt
        }
    }

    func suppressNextClipboardCapture(
        for payload: ClipboardPayload,
        duration: TimeInterval = 1.0
    ) {
        let expiresAt = Date().addingTimeInterval(max(0.1, duration))
        cliSuppressionQueue.sync {
            suppressedCliClipboardContent = payload.legacyText
            suppressedCliClipboardFingerprint = payload.fingerprint
            suppressedCliClipboardUntil = expiresAt
        }
    }

    private func shouldSuppressClipboardCapture(
        content: String?,
        payload: ClipboardPayload? = nil,
        now: Date
    ) -> Bool {
        var shouldSuppress = false
        cliSuppressionQueue.sync {
            guard suppressedCliClipboardContent != nil || suppressedCliClipboardFingerprint != nil else { return }

            if now > suppressedCliClipboardUntil {
                suppressedCliClipboardContent = nil
                suppressedCliClipboardFingerprint = nil
                suppressedCliClipboardUntil = .distantPast
                return
            }

            if let fingerprint = suppressedCliClipboardFingerprint,
               payload?.fingerprint == fingerprint {
                shouldSuppress = true
            } else if let suppressedContent = suppressedCliClipboardContent,
                      content == suppressedContent {
                shouldSuppress = true
            }
        }
        return shouldSuppress
    }

    private func shouldIgnoreStartupClipboardReplayForSession(
        recordingPath: String,
        isSameContentRewrite: Bool,
        changeCount: Int,
        observedAt: Date
    ) -> Bool {
        var evaluation: SessionStartClipboardReplayEvaluation?

        sessionsQueue.sync(flags: .barrier) {
            guard var session = earlyMonitoringSessions[recordingPath],
                  session.isActive else {
                return
            }

            if session.ignoredClipboardChangeCounts.contains(changeCount) {
                if session.lastSeenChangeCount != changeCount {
                    session.lastSeenChangeCount = changeCount
                    earlyMonitoringSessions[recordingPath] = session
                }
                evaluation = knownIgnoredClipboardReplayEvaluation(
                    session: session,
                    isSameContentRewrite: isSameContentRewrite,
                    observedAt: observedAt
                )
                return
            }

            let replayEvaluation = evaluateSessionStartClipboardReplay(
                isSameContentRewrite: isSameContentRewrite,
                sessionStartTime: session.startTime,
                guardEndsAt: session.startupReplayGuardEndsAt,
                observedAt: observedAt
            )
            evaluation = replayEvaluation

            if replayEvaluation.shouldIgnore {
                session.ignoredClipboardChangeCounts.insert(changeCount)
                session.lastSeenChangeCount = changeCount
                session.lastObservedClipboardActivityAt = observedAt
                earlyMonitoringSessions[recordingPath] = session
            } else if replayEvaluation.decision == .capturedAfterWindow {
                session.startupReplayGuardEndsAt = nil
                earlyMonitoringSessions[recordingPath] = session
            }
        }

        if let evaluation {
            logSessionStartClipboardReplayEvaluation(
                evaluation,
                source: "session",
                changeCount: changeCount
            )
        }
        return evaluation?.shouldIgnore ?? false
    }

    private func shouldIgnoreStartupClipboardReplayForGlobalCapture(
        isSameContentRewrite: Bool,
        changeCount: Int,
        observedAt: Date
    ) -> Bool {
        var shouldIgnore = false
        var evaluations: [SessionStartClipboardReplayEvaluation] = []

        sessionsQueue.sync(flags: .barrier) {
            let rootRecordingPaths = earlyMonitoringSessions.compactMap { path, session -> String? in
                guard session.isActive,
                      let group = executionGroups[session.groupId],
                      group.rootRecordingPath == path else {
                    return nil
                }
                return path
            }

            for path in rootRecordingPaths {
                guard var session = earlyMonitoringSessions[path] else { continue }

                if session.ignoredClipboardChangeCounts.contains(changeCount) {
                    evaluations.append(
                        knownIgnoredClipboardReplayEvaluation(
                            session: session,
                            isSameContentRewrite: isSameContentRewrite,
                            observedAt: observedAt
                        )
                    )
                    shouldIgnore = true
                    continue
                }

                let replayEvaluation = evaluateSessionStartClipboardReplay(
                    isSameContentRewrite: isSameContentRewrite,
                    sessionStartTime: session.startTime,
                    guardEndsAt: session.startupReplayGuardEndsAt,
                    observedAt: observedAt
                )
                evaluations.append(replayEvaluation)

                if replayEvaluation.shouldIgnore {
                    session.ignoredClipboardChangeCounts.insert(changeCount)
                    session.lastSeenChangeCount = changeCount
                    session.lastObservedClipboardActivityAt = observedAt
                    earlyMonitoringSessions[path] = session
                    shouldIgnore = true
                } else if replayEvaluation.decision == .capturedAfterWindow {
                    session.startupReplayGuardEndsAt = nil
                    earlyMonitoringSessions[path] = session
                }
            }
        }

        for evaluation in evaluations {
            logSessionStartClipboardReplayEvaluation(
                evaluation,
                source: "global",
                changeCount: changeCount
            )
        }
        return shouldIgnore
    }

    private func knownIgnoredClipboardReplayEvaluation(
        session: EarlyMonitoringSession,
        isSameContentRewrite: Bool,
        observedAt: Date
    ) -> SessionStartClipboardReplayEvaluation {
        return SessionStartClipboardReplayEvaluation(
            shouldIgnore: true,
            matchesPreviousClipboard: isSameContentRewrite,
            millisecondsFromSessionStart: Int(
                (observedAt.timeIntervalSince(session.startTime) * 1_000).rounded()
            ),
            decision: .ignoredKnownChangeCount
        )
    }

    private func logSessionStartClipboardReplayEvaluation(
        _ evaluation: SessionStartClipboardReplayEvaluation,
        source: String,
        changeCount: Int
    ) {
        logDebug(
            "[ClipboardMonitor] Startup clipboard replay evaluation " +
            "source=\(source) changeCount=\(changeCount) " +
            "matchesPreviousClipboard=\(evaluation.matchesPreviousClipboard) " +
            "millisecondsFromFolderDetection=\(evaluation.millisecondsFromSessionStart) " +
            "decision=\(evaluation.decision.rawValue)"
        )
    }

    private func mirrorGlobalClipboardChangeIntoMostRecentActiveSession(
        _ change: ClipboardChange,
        requiresCurrentChangeCount: Bool = false
    ) {
        // Commit accepted global observations before returning to global cleanup. This makes
        // the active-session copy durable even when its own faster poll initially saw nil data.
        sessionsQueue.sync(flags: .barrier) { [weak self] in
            guard let self else { return }

            guard let target = self.earlyMonitoringSessions
                .filter({ path, session in
                    guard session.isActive,
                          let group = self.executionGroups[session.groupId] else {
                        return false
                    }
                    return group.rootRecordingPath == path
                })
                .max(by: { $0.value.startTime < $1.value.startTime }) else {
                return
            }

            let recordingPath = target.key
            var session = target.value

            if requiresCurrentChangeCount, session.lastSeenChangeCount != change.changeCount {
                return
            }

            guard shouldIncludeClipboardChange(
                timestamp: change.timestamp,
                resetAt: session.clipboardContextResetAt
            ),
            !self.isInferredTransientChangeCountIgnored(change.changeCount) else {
                return
            }

            let mergeDecision = self.mergeClipboardChange(change, into: &session)
            self.earlyMonitoringSessions[recordingPath] = session
            switch mergeDecision {
            case .append:
                logDebug("[ClipboardMonitor] Mirrored global clipboard change into active session (changeCount: \(change.changeCount))")
            case .upgradeMissingContent:
                logDebug(
                    "[ClipboardMonitor] Global monitoring upgraded missing active-session clipboard content " +
                    "(changeCount: \(change.changeCount))"
                )
            case .keepExisting:
                break
            }
        }
    }

    /// Applies one logical monitor-wide budget across global history, copied
    /// pre-recording observations, active-session observations, and protected
    /// original snapshots. Eviction order is global/pre-recording first, then
    /// active-session history; original snapshots are protected for faithful
    /// restoration.
    private func enforceMonitorWideImageRetentionBudget() {
        var protectedOriginalBytes = 0
        var sessionPayloadBytes = 0
        var frozenSnapshotBytes = 0
        sessionsQueue.sync {
            for session in earlyMonitoringSessions.values {
                sessionPayloadBytes += session.preRecordingChanges.reduce(0) {
                    $0 + $1.payload.retainedImageByteCount
                }
                sessionPayloadBytes += session.clipboardChanges.reduce(0) {
                    $0 + $1.payload.retainedImageByteCount
                }
            }
            for group in executionGroups.values {
                sessionPayloadBytes += group.rootPreRecordingChanges.reduce(0) {
                    $0 + $1.payload.retainedImageByteCount
                }
            }
            protectedOriginalBytes = executionGroups.values.reduce(0) {
                $0 + ($1.rootOriginalSnapshot?.retainedImageByteCount ?? 0)
            }
            frozenSnapshotBytes = executionGroups.values.reduce(0) {
                $0 + ($1.frozenContextSnapshot?.retainedImageByteCount ?? 0)
            }
        }

        var globalPayloadBytes = 0
        globalHistoryQueue.sync(flags: .barrier) {
            globalPayloadBytes = self.globalClipboardHistory.reduce(0) {
                $0 + $1.payload.retainedImageByteCount
            }
            var total = globalPayloadBytes + sessionPayloadBytes + protectedOriginalBytes + frozenSnapshotBytes
            guard total > self.attachmentLimits.aggregateImageBytes else { return }
            for index in self.globalClipboardHistory.indices {
                guard total > self.attachmentLimits.aggregateImageBytes else { break }
                let before = self.globalClipboardHistory[index].payload.retainedImageByteCount
                guard before > 0 else { continue }
                self.globalClipboardHistory[index].payload = self.globalClipboardHistory[index].payload
                    .droppingRetainedImages(reason: .aggregateLimit)
                globalPayloadBytes -= before
                total -= before
                logDebug(
                    "[ClipboardMonitor] Evicted pre-recording clipboard image " +
                    "(reason: aggregate-limit, retainedImageBytes: \(max(0, globalPayloadBytes)))"
                )
            }
        }

        // Session queues are mutated separately from global history to avoid
        // re-entrant queue waits. The current global byte total is bounded by
        // the preceding barrier.
        sessionsQueue.sync(flags: .barrier) {
            var totalSessionBytes = 0
            for session in self.earlyMonitoringSessions.values {
                totalSessionBytes += session.preRecordingChanges.reduce(0) {
                    $0 + $1.payload.retainedImageByteCount
                }
                totalSessionBytes += session.clipboardChanges.reduce(0) {
                    $0 + $1.payload.retainedImageByteCount
                }
            }
            for group in self.executionGroups.values {
                totalSessionBytes += group.rootPreRecordingChanges.reduce(0) {
                    $0 + $1.payload.retainedImageByteCount
                }
            }
            var total = globalPayloadBytes + totalSessionBytes + protectedOriginalBytes + frozenSnapshotBytes
            guard total > self.attachmentLimits.aggregateImageBytes else { return }

            func evict(_ payload: inout ClipboardPayload, owner: String) {
                let before = payload.retainedImageByteCount
                guard before > 0, total > self.attachmentLimits.aggregateImageBytes else { return }
                payload = payload.droppingRetainedImages(reason: .aggregateLimit)
                total -= before
                logDebug(
                    "[ClipboardMonitor] Evicted \(owner) clipboard image " +
                    "(reason: aggregate-limit, retainedImageBytes: \(max(0, total - protectedOriginalBytes)))"
                )
            }

            let sessionPaths = Array(self.earlyMonitoringSessions.keys)
            for path in sessionPaths {
                guard var session = self.earlyMonitoringSessions[path] else { continue }
                for index in session.preRecordingChanges.indices {
                    evict(&session.preRecordingChanges[index].payload, owner: "pre-recording")
                    if total <= self.attachmentLimits.aggregateImageBytes { break }
                }
                self.earlyMonitoringSessions[path] = session
                if total <= self.attachmentLimits.aggregateImageBytes { break }
            }
            if total > self.attachmentLimits.aggregateImageBytes {
                for path in sessionPaths {
                    guard var session = self.earlyMonitoringSessions[path] else { continue }
                    for index in session.clipboardChanges.indices {
                        evict(&session.clipboardChanges[index].payload, owner: "active-session")
                        if total <= self.attachmentLimits.aggregateImageBytes { break }
                    }
                    self.earlyMonitoringSessions[path] = session
                    if total <= self.attachmentLimits.aggregateImageBytes { break }
                }
            }
            if total > self.attachmentLimits.aggregateImageBytes {
                for groupId in Array(self.executionGroups.keys) {
                    guard var group = self.executionGroups[groupId] else { continue }
                    for index in group.rootPreRecordingChanges.indices {
                        evict(&group.rootPreRecordingChanges[index].payload, owner: "root-pre-recording")
                        if total <= self.attachmentLimits.aggregateImageBytes { break }
                    }
                    self.executionGroups[groupId] = group
                    if total <= self.attachmentLimits.aggregateImageBytes { break }
                }
            }
        }
    }
    
    /// Checks for clipboard changes and maintains the lightweight rolling buffer
    private func checkGlobalClipboardChange() {
        let pasteboard = NSPasteboard.general
        guard let pasteboardSnapshot = captureClipboardPasteboardSnapshot(
            from: pasteboard,
            source: "global",
            includeAttachments: clipboardAttachmentsEnabled,
            attachmentLimits: attachmentLimits
        ) else {
            logNoContentIfNeeded(
                "global_unstable_pasteboard_snapshot",
                "[ClipboardMonitor] Global monitoring deferred an unstable pasteboard snapshot"
            )
            return
        }
        let currentChangeCount = pasteboardSnapshot.changeCount
        let currentClipboard = pasteboardSnapshot.payload.textProjection(
            attachmentsEnabled: clipboardAttachmentsEnabled
        ) ?? (clipboardAttachmentsEnabled ? nil : pasteboardSnapshot.content)
        let now = Date()
        
        globalHistoryQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            // A poll sampled before an explicit reset may reach this queue afterward.
            // Ignore it entirely so it cannot roll the baseline backward or repopulate history.
            guard shouldIncludeClipboardChange(
                timestamp: now,
                resetAt: self.clipboardContextResetAt
            ) else {
                return
            }
            
            // On first check, just record what's there without treating it as a "change"
            if self.isFirstGlobalCheck {
                self.logClipboardObservationDiagnostic(
                    source: "global-baseline",
                    snapshot: pasteboardSnapshot,
                    observedAt: now,
                    previousChangeCount: nil,
                    previousObservedAt: nil,
                    previousContent: nil
                )
                self.isFirstGlobalCheck = false
                self.lastSeenClipboardContent = currentClipboard
                self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                self.lastSeenChangeCount = currentChangeCount
                self.lastSeenClipboardChangeObservedAt = now
                logDebug("[ClipboardMonitor] Global monitoring initialized - recording baseline clipboard content (changeCount: \(currentChangeCount))")
                return
            }
            
            // Use changeCount for more reliable change detection - track ANY clipboard operation
            if currentChangeCount != self.lastSeenChangeCount {
                self.logClipboardObservationDiagnostic(
                    source: "global",
                    snapshot: pasteboardSnapshot,
                    observedAt: now,
                    previousChangeCount: self.lastSeenChangeCount,
                    previousObservedAt: self.lastSeenClipboardChangeObservedAt,
                    previousContent: self.lastSeenClipboardContent
                )
                self.lastSeenClipboardChangeObservedAt = now

                if self.shouldSuppressClipboardCapture(
                    content: currentClipboard,
                    payload: pasteboardSnapshot.payload,
                    now: now
                ) {
                    self.cancelInferredTransientRestoreCandidate(
                        boundaryChangeCount: currentChangeCount,
                        observedAt: now
                    )
                    self.lastSeenClipboardContent = currentClipboard
                    self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                    self.lastSeenChangeCount = currentChangeCount
                    logDebug("[ClipboardMonitor] Global monitoring skipped Macrowhisper copy-action clipboard write")
                    return
                }

                let markerType = self.ignoredMarkerType(in: pasteboardSnapshot.types)
                let markerSequenceDecision = self.ignoredMarkerSequenceDecision(
                    changeCount: currentChangeCount,
                    containsIgnoredMarker: markerType != nil,
                    observedAt: now
                )
                self.logMarkerSequenceDecision(
                    markerSequenceDecision,
                    markerType: markerType,
                    changeCount: currentChangeCount,
                    source: "Global monitoring"
                )
                if markerSequenceDecision.shouldIgnore {
                    self.cancelInferredTransientRestoreCandidate(
                        boundaryChangeCount: currentChangeCount,
                        observedAt: now
                    )
                    if markerType != nil {
                        let markerFrontAppName = resolveFrontAppIdentity()?.localizedName ?? ""
                        self.performGlobalRetroactiveCleanup(now: now, appName: markerFrontAppName)
                    }
                    self.lastSeenClipboardContent = currentClipboard
                    self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                    self.lastSeenChangeCount = currentChangeCount
                    return
                }

                let isSameContentRewrite: Bool
                if self.lastSeenClipboardPayload != nil {
                    isSameContentRewrite = isSameClipboardPayloadRewrite(
                        currentPayload: pasteboardSnapshot.payload,
                        previousPayload: self.lastSeenClipboardPayload
                    )
                } else {
                    isSameContentRewrite = isSameContentClipboardRewrite(
                        currentClipboard: currentClipboard,
                        previousClipboard: self.lastSeenClipboardContent
                    )
                }

                let pendingRestoreDecision = self.inferredTransientRestoreDecision(
                    changeCount: currentChangeCount,
                    content: currentClipboard,
                    payload: pasteboardSnapshot.payload,
                    containsIgnoredMarker: false,
                    observedAt: now,
                    previousChangeCount: self.lastSeenChangeCount,
                    previousContent: self.lastSeenClipboardContent,
                    previousPayload: self.lastSeenClipboardPayload,
                    canArmCandidate: false
                )
                self.logInferredTransientRestoreDecision(
                    pendingRestoreDecision,
                    source: "Global monitoring"
                )
                if pendingRestoreDecision.shouldIgnore {
                    let transactionChangeCounts = pendingRestoreDecision.transactionChangeCounts
                    self.removeInferredTransientTransactionFromGlobalHistory(transactionChangeCounts)
                    self.excludeInferredTransientTransactionFromSessions(transactionChangeCounts)
                    self.lastSeenClipboardContent = currentClipboard
                    self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                    self.lastSeenChangeCount = currentChangeCount
                    return
                }

                if self.shouldIgnoreStartupClipboardReplayForGlobalCapture(
                    isSameContentRewrite: isSameContentRewrite,
                    changeCount: currentChangeCount,
                    observedAt: now
                ) {
                    self.cancelInferredTransientRestoreCandidate(
                        boundaryChangeCount: currentChangeCount,
                        observedAt: now
                    )
                    self.lastSeenClipboardContent = currentClipboard
                    self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                    self.lastSeenChangeCount = currentChangeCount
                    return
                }

                // Only resolve the front app once the operation is eligible for app attribution.
                let frontApp = resolveFrontAppIdentity()
                let appName = frontApp?.localizedName ?? ""
                let bundleId = frontApp?.bundleIdentifier ?? ""

                // Check if the captured app should be ignored (using the app info we captured atomically)
                let shouldIgnoreAppFlag = self.shouldIgnoreApp(appName: appName, bundleId: bundleId)
                
                if shouldIgnoreAppFlag {
                    self.cancelInferredTransientRestoreCandidate(
                        boundaryChangeCount: currentChangeCount,
                        observedAt: now
                    )
                    self.performGlobalRetroactiveCleanup(now: now, appName: appName)
                } else {
                    let allowAdjacentStartupCandidate = self.allowsAdjacentStartupTransientCandidate(
                        for: nil,
                        changeCount: currentChangeCount,
                        observedAt: now
                    )
                    let inferredRestoreDecision = self.inferredTransientRestoreDecision(
                        changeCount: currentChangeCount,
                        content: currentClipboard,
                        payload: pasteboardSnapshot.payload,
                        containsIgnoredMarker: false,
                        observedAt: now,
                        previousChangeCount: self.lastSeenChangeCount,
                        previousContent: self.lastSeenClipboardContent,
                        previousPayload: self.lastSeenClipboardPayload,
                        restoreWindow: allowAdjacentStartupCandidate
                            ? ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW
                            : INFERRED_TRANSIENT_RESTORE_WINDOW,
                        allowAdjacentInitialCount: allowAdjacentStartupCandidate
                    )
                    self.logInferredTransientRestoreDecision(
                        inferredRestoreDecision,
                        source: "Global monitoring"
                    )
                    if inferredRestoreDecision.shouldIgnore {
                        let transactionChangeCounts = inferredRestoreDecision.transactionChangeCounts
                        self.removeInferredTransientTransactionFromGlobalHistory(transactionChangeCounts)
                        self.excludeInferredTransientTransactionFromSessions(transactionChangeCounts)
                        self.lastSeenClipboardContent = currentClipboard
                        self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                        self.lastSeenChangeCount = currentChangeCount
                        return
                    }

                    // Track ANY clipboard operation (even if content is identical) as changeCount indicates a copy action occurred
                    // Store the app info with the change so we know which app made it
                    let change = ClipboardChange(
                        content: currentClipboard,
                        payload: pasteboardSnapshot.payload,
                        timestamp: now, 
                        changeCount: currentChangeCount,
                        frontAppName: appName.isEmpty ? nil : appName,
                        frontAppBundleId: bundleId.isEmpty ? nil : bundleId,
                        pasteboardTypes: pasteboardSnapshot.types.map(\.rawValue).sorted(),
                        isSameContentRewrite: isSameContentRewrite
                    )
                    self.globalClipboardHistory.append(change)
                    self.mirrorGlobalClipboardChangeIntoMostRecentActiveSession(change)
                    
                    // Prevent unbounded growth by removing oldest entries if we exceed the limit
                    if self.globalClipboardHistory.count > MAX_GLOBAL_CLIPBOARD_HISTORY {
                        let excessCount = self.globalClipboardHistory.count - MAX_GLOBAL_CLIPBOARD_HISTORY
                        self.globalClipboardHistory.removeFirst(excessCount)
                        logDebug("[ClipboardMonitor] Trimmed \(excessCount) old global history entries to stay within bounds")
                    }
                    
                    logDebug("[ClipboardMonitor] Global monitoring detected clipboard operation from '\(appName)' (changeCount: \(currentChangeCount))")
                    logDebug("[ClipboardMonitor] Global history size: \(self.globalClipboardHistory.count)/\(MAX_GLOBAL_CLIPBOARD_HISTORY)")
                }
                
                // Always update last seen values even if we're ignoring this change
                self.lastSeenClipboardContent = currentClipboard
                self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                self.lastSeenChangeCount = currentChangeCount
            }
            
            // Upgrade a captured but initially empty image operation without
            // refreshing its buffer age or app attribution.
            if currentChangeCount == self.lastSeenChangeCount,
               self.clipboardAttachmentsEnabled,
               self.ignoredMarkerType(in: pasteboardSnapshot.types) == nil,
               !self.shouldSuppressClipboardCapture(content: currentClipboard, payload: pasteboardSnapshot.payload, now: now),
               !self.isInferredTransientChangeCountIgnored(currentChangeCount),
               let index = self.globalClipboardHistory.firstIndex(where: { $0.changeCount == currentChangeCount }),
               let upgraded = self.upgradedClipboardImageChange(self.globalClipboardHistory[index], snapshot: pasteboardSnapshot) {
                self.globalClipboardHistory[index] = upgraded
                self.lastSeenClipboardContent = currentClipboard
                self.lastSeenClipboardPayload = pasteboardSnapshot.payload
                self.mirrorGlobalClipboardChangeIntoMostRecentActiveSession(upgraded, requiresCurrentChangeCount: true)
                logDebug("[ClipboardMonitor] Global monitoring resolved late image data (changeCount: \(currentChangeCount))")
            }

            // Clean up old entries beyond the buffer time (keep only last 5 seconds)
            let cutoffTime = now.addingTimeInterval(-self.preRecordingBuffer)
            let beforeCount = self.globalClipboardHistory.count
            self.globalClipboardHistory.removeAll { change in
                change.timestamp < cutoffTime
            }
            let afterCount = self.globalClipboardHistory.count
            
            // Only log cleanup if entries were actually removed (reduce log noise)
            if beforeCount != afterCount {
                logDebug("[ClipboardMonitor] Global cleanup: removed \(beforeCount - afterCount) old entries, \(afterCount) remaining")
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.enforceMonitorWideImageRetentionBudget()
            }
        }
    }
    
    // MARK: - Memory Management and Bounds Control
    
    /// Starts periodic cleanup to prevent memory growth from unbounded arrays
    private func startPeriodicCleanup() {
        let interval = cleanupInterval
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performPeriodicCleanup()
        }
        RunLoop.main.add(cleanupTimer!, forMode: .common)
        logDebug("[ClipboardMonitor] Started periodic cleanup (every \(String(format: "%.1f", interval))s, based on clipboardBuffer: \(String(format: "%.1f", preRecordingBuffer))s)")
    }
    
    /// Stops periodic cleanup timer
    private func stopPeriodicCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        logDebug("[ClipboardMonitor] Stopped periodic cleanup")
    }
    
    /// Performs cleanup of old data to prevent memory growth
    private func performPeriodicCleanup() {
        let startTime = Date()
        var cleanupActions: [String] = []

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let removedCount = self.cleanupGeneratedAttachmentFilesIfIdle()
            if removedCount > 0 {
                logDebug(
                    "[ClipboardMonitor] Removed \(removedCount) generated attachment " +
                    "generation(s) no longer referenced by the clipboard"
                )
            }
        }
        
        // Clean up global clipboard history (already has time-based cleanup, but add count bounds)
        globalHistoryQueue.async(flags: .barrier) {
            let beforeGlobalCount = self.globalClipboardHistory.count
            
            // Keep only the most recent entries within bounds
            if self.globalClipboardHistory.count > MAX_GLOBAL_CLIPBOARD_HISTORY {
                let excessCount = self.globalClipboardHistory.count - MAX_GLOBAL_CLIPBOARD_HISTORY
                self.globalClipboardHistory.removeFirst(excessCount)
                cleanupActions.append("trimmed \(excessCount) excess global history entries")
            }
            
            let afterGlobalCount = self.globalClipboardHistory.count
            if beforeGlobalCount != afterGlobalCount {
                cleanupActions.append("global history: \(beforeGlobalCount) → \(afterGlobalCount)")
            }
        }
        
        // Clean up session clipboard changes and remove old inactive sessions
        sessionsQueue.async(flags: .barrier) {
            let beforeSessionCount = self.earlyMonitoringSessions.count
            var totalClipboardChangesBefore = 0
            var totalClipboardChangesAfter = 0
            
            // Count total clipboard changes before cleanup
            for session in self.earlyMonitoringSessions.values {
                totalClipboardChangesBefore += session.clipboardChanges.count
            }
            
            // Remove inactive sessions older than 5 minutes
            let cutoffTime = Date().addingTimeInterval(-300) // 5 minutes
            let inactiveSessionKeys = self.earlyMonitoringSessions.compactMap { (key, session) in
                (!session.isActive && session.startTime < cutoffTime) ? key : nil
            }
            
            for key in inactiveSessionKeys {
                self.earlyMonitoringSessions.removeValue(forKey: key)
            }
            
            // Trim clipboard changes in remaining sessions
            for (key, var session) in self.earlyMonitoringSessions {
                if session.clipboardChanges.count > MAX_SESSION_CLIPBOARD_CHANGES {
                    let excessCount = session.clipboardChanges.count - MAX_SESSION_CLIPBOARD_CHANGES
                    session.clipboardChanges.removeFirst(excessCount)
                    self.earlyMonitoringSessions[key] = session
                }
                totalClipboardChangesAfter += session.clipboardChanges.count
            }
            
            let afterSessionCount = self.earlyMonitoringSessions.count
            
            if beforeSessionCount != afterSessionCount || totalClipboardChangesBefore != totalClipboardChangesAfter {
                cleanupActions.append("sessions: \(beforeSessionCount) → \(afterSessionCount), changes: \(totalClipboardChangesBefore) → \(totalClipboardChangesAfter)")
            }
            
            if inactiveSessionKeys.count > 0 {
                cleanupActions.append("removed \(inactiveSessionKeys.count) inactive sessions")
            }
        }
        
        // Log cleanup results if any actions were taken
        DispatchQueue.main.async {
            let duration = Date().timeIntervalSince(startTime)
            if !cleanupActions.isEmpty {
                logDebug("[ClipboardMonitor] Periodic cleanup (\(String(format: "%.2f", duration * 1000))ms): \(cleanupActions.joined(separator: ", "))")
            }
        }
    }

    /// Serializes disk cleanup with execution-group creation/finalization. No
    /// generated file is removed while an active group might still restore or
    /// hand off a file URL captured from an earlier Macrowhisper handoff.
    @discardableResult
    private func cleanupGeneratedAttachmentFilesIfIdle() -> Int {
        sessionsQueue.sync {
            guard executionGroups.isEmpty else { return 0 }
            return attachmentFileStore.cleanupUnused()
        }
    }
} 
