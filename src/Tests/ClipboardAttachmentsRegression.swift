import Foundation
import Cocoa

private func assertAttachment(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func makeAttachmentImageData(
    fileType: NSBitmapImageRep.FileType,
    red: UInt8,
    green: UInt8,
    blue: UInt8
) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 1,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let bytes = bitmap.bitmapData else {
        fatalError("Could not create attachment image fixture")
    }
    for pixel in 0..<2 {
        let offset = pixel * 4
        bytes[offset] = red
        bytes[offset + 1] = green
        bytes[offset + 2] = blue
        bytes[offset + 3] = 0xff
    }
    guard let data = bitmap.representation(using: fileType, properties: [:]) else {
        fatalError("Could not encode attachment image fixture")
    }
    return data
}

private func runClipboardAttachmentsRegression() {
    let png = makeAttachmentImageData(fileType: .png, red: 0x22, green: 0x88, blue: 0xcc)
    let tiff = makeAttachmentImageData(fileType: .tiff, red: 0xcc, green: 0x66, blue: 0x11)
    let fileURL = URL(fileURLWithPath: "/private/tmp/clipboard-attachment.txt")
    let payload = makeClipboardPayload(items: [
        ClipboardPasteboardItemRepresentations(text: "incidental", fileURL: fileURL),
        ClipboardPasteboardItemRepresentations(pngData: png, tiffData: tiff),
        ClipboardPasteboardItemRepresentations(tiffData: tiff)
    ], legacyText: "legacy")

    assertAttachment(payload.kind == .attachments, "file/image operations are attachment-classified")
    assertAttachment(payload.items.count == 3, "ordered semantic items are retained")
    assertAttachment(payload.items[0] == .fileURL(fileURL), "file URLs remain URL metadata")
    assertAttachment(payload.items[1] == .imagePNG(png), "PNG is preferred over TIFF")
    assertAttachment(payload.items[2] == .imageTIFF(tiff), "TIFF is used as image fallback")
    let missingPNGWithTIFFFallback = makeClipboardPayload(items: [
        ClipboardPasteboardItemRepresentations(
            pngData: nil,
            tiffData: tiff,
            hasPNGRepresentation: true,
            hasTIFFRepresentation: true
        )
    ])
    assertAttachment(
        missingPNGWithTIFFFallback.items == [.imageTIFF(tiff)],
        "a provider that cannot vend advertised PNG data falls back to its valid TIFF"
    )
    assertAttachment(payload.textProjection(attachmentsEnabled: true) == nil, "incidental attachment text is not context fallback")
    assertAttachment(payload.textProjection(attachmentsEnabled: false) == "legacy", "existing text projection is preserved when disabled")

    let oversized = makeClipboardPayload(
        items: [ClipboardPasteboardItemRepresentations(
            text: "should-not-fallback",
            pngData: Data(repeating: 1, count: 9),
            hasPNGRepresentation: true
        )],
        legacyText: "should-not-fallback",
        limits: ClipboardAttachmentLimits(perImageBytes: 8, aggregateImageBytes: 32)
    )
    assertAttachment(oversized.kind == .attachments, "oversized images stay attachment-classified")
    assertAttachment(oversized.textProjection(attachmentsEnabled: true) == nil, "oversized images do not fall back to incidental text")
    if case .unavailableImage(_, _, let reason) = oversized.items[0] {
        assertAttachment(reason == .perImageLimit, "oversized diagnostics retain per-image drop reason")
    } else {
        assertAttachment(false, "oversized image is represented as unavailable attachment")
    }
    let unavailableMixedHandoff = makeWritableAttachmentHandoffPayload(
        ClipboardPayload(items: [.text("must not escape"), oversized.items[0]], legacyText: "must not escape")
    )
    assertAttachment(unavailableMixedHandoff.items.isEmpty, "oversized attachment handoff never degrades to neighboring or incidental text")

    let budgeted = applyClipboardImageRetentionBudget(
        to: [
            ClipboardPayload(items: [.imagePNG(Data(repeating: 1, count: 7))]),
            ClipboardPayload(items: [.imageTIFF(Data(repeating: 2, count: 7))])
        ],
        limits: ClipboardAttachmentLimits(perImageBytes: 8, aggregateImageBytes: 8)
    )
    assertAttachment(budgeted.retainedImageBytes == 7, "aggregate image budget is enforced")
    if case .unavailableImage(_, _, let reason) = budgeted.payloads[0].items[0] {
        assertAttachment(reason == .aggregateLimit, "oldest payload is evicted first")
    } else {
        assertAttachment(false, "oldest payload is represented as unavailable after eviction")
    }
    assertAttachment(
        ClipboardPayload(items: [.imagePNG(png)]).fingerprint != ClipboardPayload(items: [.imageTIFF(png)]).fingerprint,
        "fingerprints are representation-aware"
    )

    let original = makeClipboardOriginalSnapshot(
        items: [
            ClipboardPasteboardItemRepresentations(text: "text", fileURL: fileURL, pngData: png),
            ClipboardPasteboardItemRepresentations(tiffData: tiff)
        ],
        legacyText: "text",
        changeCount: 17
    )
    assertAttachment(original.items.count == 2, "original snapshot preserves pasteboard item order")
    assertAttachment(original.items[0].representations.count == 3, "original snapshot preserves supported representations")
    assertAttachment(original.items[0].representations[1] == .fileURL(fileURL), "original snapshot retains file URL without reading it")

    let droppedOriginal = makeClipboardOriginalSnapshot(
        items: [ClipboardPasteboardItemRepresentations(
            text: "incidental-only",
            pngData: Data(repeating: 1, count: 9),
            hasPNGRepresentation: true
        )],
        legacyText: "incidental-only",
        limits: ClipboardAttachmentLimits(perImageBytes: 8, aggregateImageBytes: 32)
    )
    assertAttachment(
        droppedOriginal.items.isEmpty,
        "original restoration does not fall back to incidental text when attachment bytes are dropped"
    )
    assertAttachment(
        !droppedOriginal.isComplete && droppedOriginal.omittedAttachmentCount == 1,
        "an incomplete original snapshot records why faithful restoration is unavailable"
    )

    let textA = ClipboardPayload(items: [.text("text A")], legacyText: "text A")
    let screenshot = ClipboardPayload(items: [.imagePNG(png)], legacyText: "incidental screenshot text")
    let textB = ClipboardPayload(items: [.text("text B")], legacyText: "text B")
    let secondFileURL = URL(fileURLWithPath: "/private/tmp/clipboard-attachment-2.pdf")
    let finderSelection = ClipboardPayload(
        items: [.fileURL(fileURL), .fileURL(secondFileURL)],
        legacyText: "incidental Finder paths"
    )
    assertAttachment(
        makeWritableAttachmentHandoffPayload(
            ClipboardPayload(items: [.text("not for final clipboard"), .fileURL(fileURL)])
        ).items == [.fileURL(fileURL)],
        "attachment handoff writes only native attachments, not text from a mixed operation"
    )

    let textThenImage = makeClipboardOperationContextSnapshot(
        orderedPayloads: [textA, screenshot],
        fallbackTextCandidates: ["text A", "incidental screenshot text"],
        swResult: "",
        attachmentsEnabled: true
    )
    assertAttachment(textThenImage.representations.single.isEmpty, "stacking off: a latest image produces empty text context")
    assertAttachment(textThenImage.singleAttachmentCandidates == [screenshot], "stacking off: a latest image is the handoff candidate")

    let imageThenText = makeClipboardOperationContextSnapshot(
        orderedPayloads: [screenshot, textA],
        fallbackTextCandidates: ["incidental screenshot text", "text A"],
        swResult: "",
        attachmentsEnabled: true
    )
    assertAttachment(imageThenText.representations.single == "text A", "stacking off: latest text wins after an image")
    assertAttachment(imageThenText.singleAttachmentCandidates.isEmpty, "stacking off: an older image is not handed off")

    let multiFile = makeClipboardOperationContextSnapshot(
        orderedPayloads: [finderSelection],
        fallbackTextCandidates: ["incidental Finder paths"],
        swResult: "",
        attachmentsEnabled: true
    )
    assertAttachment(multiFile.representations.single.isEmpty, "Finder multi-file copy is one attachment operation")
    assertAttachment(multiFile.singleAttachmentCandidates.first?.attachmentItems.count == 2, "all Finder items remain in the winning operation")

    let stacked = makeClipboardOperationContextSnapshot(
        orderedPayloads: [textA, screenshot, textB, finderSelection],
        fallbackTextCandidates: ["text A", "incidental screenshot text", "text B", "incidental Finder paths"],
        swResult: "",
        attachmentsEnabled: true
    )
    assertAttachment(
        stacked.representations.stacked == "<clipboard-context-1>\ntext A\n</clipboard-context-1>\n\n<clipboard-context-2>\ntext B\n</clipboard-context-2>",
        "stacking on: only text operations contribute to the XML context"
    )
    assertAttachment(stacked.stackedAttachmentCandidates == [screenshot, finderSelection], "stacking on: attachment operations retain capture order")
    assertAttachment(stacked.stackedAttachmentCandidates.flatMap(\.attachmentItems).count == 3, "stacking on: heterogeneous attachment items accumulate")

    let attachmentsOnly = makeClipboardOperationContextSnapshot(
        orderedPayloads: [screenshot, finderSelection],
        fallbackTextCandidates: ["incidental screenshot text", "incidental Finder paths"],
        swResult: "",
        attachmentsEnabled: true
    )
    assertAttachment(attachmentsOnly.representations.single.isEmpty && attachmentsOnly.representations.stacked.isEmpty, "attachment-only context leaves the string placeholder empty")

    let disabled = makeClipboardOperationContextSnapshot(
        orderedPayloads: [textA, screenshot],
        fallbackTextCandidates: ["text A", "incidental screenshot text"],
        swResult: "",
        attachmentsEnabled: false
    )
    assertAttachment(disabled.representations.single == "incidental screenshot text", "disabled attachment handling preserves existing text projection")

    let successfulPolicy = ClipboardAttachmentHandoffPolicy(
        enabled: true,
        consumer: .actionExecutor,
        wholeChainSucceeded: true
    )
    let failedPolicy = ClipboardAttachmentHandoffPolicy(
        enabled: true,
        consumer: .actionExecutor,
        wholeChainSucceeded: false,
        priorChainFailure: true
    )
    assertAttachment(
        shouldEnableAttachmentHandoffForExecution(attachmentsEnabled: true),
        "clipboardAttachments enables handoff without requiring clipboardContext"
    )
    assertAttachment(
        !shouldEnableAttachmentHandoffForExecution(attachmentsEnabled: false),
        "disabled clipboardAttachments does not enable handoff"
    )
    assertAttachment(successfulPolicy.isEligible, "a successful explicit consumer is handoff-eligible")
    assertAttachment(!failedPolicy.isEligible, "a prior chain failure prevents attachment handoff")
    assertAttachment(
        !updatedClipboardAttachmentHandoffPolicy(
            existing: failedPolicy,
            consumer: .actionExecutor,
            wholeChainSucceeded: true,
            priorChainFailure: false
        ).isEligible,
        "a later successful consumer cannot erase an earlier chain failure"
    )

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("macrowhisper.clipboard-attachments-regression.\(UUID().uuidString)"))
    pasteboard.setString("keep when capture is unavailable", forType: .string)
    assertAttachment(
        !writeClipboardOriginalSnapshot(nil, to: pasteboard),
        "an unavailable original snapshot is not treated as an empty clipboard"
    )
    assertAttachment(
        pasteboard.string(forType: .string) == "keep when capture is unavailable",
        "an unavailable original snapshot leaves the current clipboard untouched"
    )

    let dualImagePasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.dual-image-representations.\(UUID().uuidString)")
    )
    let dualImageItem = NSPasteboardItem()
    dualImageItem.setData(png, forType: .png)
    dualImageItem.setData(tiff, forType: .tiff)
    dualImagePasteboard.writeObjects([dualImageItem])
    let dualImageSnapshot = captureClipboardPasteboardSnapshot(
        from: dualImagePasteboard,
        source: "regression-dual-image",
        captureOriginalSnapshot: true
    )
    assertAttachment(
        dualImageSnapshot?.payload.items == [.imagePNG(png)],
        "semantic attachment capture still chooses PNG when PNG and TIFF are both advertised"
    )
    assertAttachment(
        dualImageSnapshot?.originalSnapshot?.items.first?.representations == [.png(png), .tiff(tiff)],
        "original capture retains both advertised PNG and TIFF representations"
    )

    let unsupportedPasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.unsupported-representation.\(UUID().uuidString)")
    )
    let unsupportedItem = NSPasteboardItem()
    unsupportedItem.setData(
        Data([0x01, 0x02]),
        forType: NSPasteboard.PasteboardType("com.macrowhisper.regression-private-type")
    )
    unsupportedPasteboard.writeObjects([unsupportedItem])
    let unsupportedSnapshot = captureClipboardPasteboardSnapshot(
        from: unsupportedPasteboard,
        source: "regression-unsupported-original",
        captureOriginalSnapshot: true
    )?.originalSnapshot
    assertAttachment(
        unsupportedSnapshot?.isComplete == false,
        "an unsupported-only clipboard is not mistaken for a known empty clipboard"
    )
    let unsupportedChangeCount = unsupportedPasteboard.changeCount
    assertAttachment(
        !writeClipboardOriginalSnapshot(unsupportedSnapshot, to: unsupportedPasteboard),
        "unsupported-only original restoration refuses a destructive partial write"
    )
    assertAttachment(
        unsupportedPasteboard.changeCount == unsupportedChangeCount,
        "refused unsupported-only restoration leaves the clipboard untouched"
    )
    let unsupportedCommitStore = ClipboardAttachmentFileStore(
        rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "macrowhisper-unsupported-commit-\(UUID().uuidString)",
            isDirectory: true
        )
    )
    let borrowedOnlyHandoff = unsupportedCommitStore.prepare(
        ClipboardPayload(items: [.fileURL(fileURL)])
    )
    assertAttachment(
        unsupportedCommitStore.commitResult(borrowedOnlyHandoff, to: unsupportedPasteboard) ==
            .preservedCurrentClipboard,
        "attachment commit reports when an unsupported current clipboard must be preserved"
    )
    assertAttachment(
        unsupportedPasteboard.changeCount == unsupportedChangeCount,
        "preserved-current result never replaces the unsupported clipboard"
    )

    let fileListOriginal = makeClipboardOriginalSnapshot(
        items: [
            ClipboardPasteboardItemRepresentations(fileURL: fileURL),
            ClipboardPasteboardItemRepresentations(fileURL: secondFileURL)
        ],
        legacyText: nil
    )
    assertAttachment(writeClipboardOriginalSnapshot(fileListOriginal, to: pasteboard), "multi-file original restoration writes successfully")
    let restoredFileListData = pasteboard.data(forType: CLIPBOARD_FILENAMES_PASTEBOARD_TYPE)
    let restoredFileList = restoredFileListData.flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String]
    } ?? nil
    assertAttachment(restoredFileList == [fileURL.path, secondFileURL.path], "multi-file original restoration uses one eager filename array")

    let materializationRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("macrowhisper-attachment-file-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: materializationRoot) }
    let borrowedDirectory = materializationRoot.appendingPathComponent("borrowed", isDirectory: true)
    try? FileManager.default.createDirectory(at: borrowedDirectory, withIntermediateDirectories: true)
    let borrowedFile = borrowedDirectory.appendingPathComponent("existing.pdf")
    let borrowedData = Data("existing file".utf8)
    try? borrowedData.write(to: borrowedFile)
    let generatedRoot = materializationRoot.appendingPathComponent("generated", isDirectory: true)
    let attachmentStore = ClipboardAttachmentFileStore(rootDirectory: generatedRoot)
    let mixedFileHandoff = attachmentStore.prepare(ClipboardPayload(items: [
        .imageTIFF(tiff),
        .fileURL(borrowedFile),
        .imagePNG(png)
    ]))
    assertAttachment(mixedFileHandoff.fileURLs.count == 3, "raw and existing attachments become one ordered file list")
    assertAttachment(mixedFileHandoff.materializedImageCount == 2, "PNG and TIFF representations are materialized")
    assertAttachment(mixedFileHandoff.fileURLs[0].pathExtension == "png", "raw TIFF materialization is normalized to PNG")
    assertAttachment(mixedFileHandoff.fileURLs[1] == borrowedFile.standardizedFileURL, "existing file URLs remain borrowed in place")
    assertAttachment(mixedFileHandoff.fileURLs[2].pathExtension == "png", "PNG materialization preserves its extension")
    let transcodedTIFFData = try? Data(contentsOf: mixedFileHandoff.fileURLs[0])
    assertAttachment(
        transcodedTIFFData.flatMap(NSBitmapImageRep.init(data:)) != nil,
        "materialized TIFF pixels produce a decodable PNG file"
    )
    assertAttachment(mixedFileHandoff.transcodedTIFFImageCount == 1, "TIFF-to-PNG normalization is diagnosed")
    assertAttachment(mixedFileHandoff.imageNormalizationFailureCount == 0, "valid raw images have no normalization failures")
    assertAttachment((try? Data(contentsOf: mixedFileHandoff.fileURLs[2])) == png, "materialized PNG bytes are exact")
    assertAttachment(attachmentStore.commit(mixedFileHandoff, to: pasteboard), "ordered attachment file-list commits successfully")
    let filenamesData = pasteboard.data(forType: CLIPBOARD_FILENAMES_PASTEBOARD_TYPE)
    let filenames = filenamesData.flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String]
    } ?? nil
    assertAttachment(filenames == mixedFileHandoff.fileURLs.map(\.path), "eager filename-array payload preserves every attachment in order")
    assertAttachment(
        mixedFileHandoff.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
        "a successful handoff leaves every published file durably present"
    )
    let readBackFileURLs = (pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) ?? []).compactMap { ($0 as? NSURL) as URL? }
    assertAttachment(readBackFileURLs.map(\.standardizedFileURL) == mixedFileHandoff.fileURLs, "AppKit reads every materialized attachment as a file URL")
    assertAttachment(pasteboard.data(forType: .png) == nil && pasteboard.data(forType: .tiff) == nil, "handoff no longer advertises first-item raw image data")
    assertAttachment(attachmentStore.cleanupUnused(pasteboard: pasteboard) == 0, "current clipboard ownership preserves generated files")
    assertAttachment(FileManager.default.fileExists(atPath: mixedFileHandoff.fileURLs[0].path), "generated files remain readable while clipboard-owned")
    let restartedAttachmentStore = ClipboardAttachmentFileStore(rootDirectory: generatedRoot)
    assertAttachment(restartedAttachmentStore.cleanupUnused(pasteboard: pasteboard) == 0, "service restart cleanup preserves the current clipboard handoff")
    assertAttachment(FileManager.default.fileExists(atPath: mixedFileHandoff.fileURLs[2].path), "restart preservation keeps every generated image readable")

    let deferredCleanupRoot = materializationRoot.appendingPathComponent(
        "deferred-cleanup",
        isDirectory: true
    )
    let deferredCleanupStore = ClipboardAttachmentFileStore(
        rootDirectory: deferredCleanupRoot,
        retentionInterval: 0
    )
    let deferredCleanupSourcePasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.attachment-deferred-source.\(UUID().uuidString)")
    )
    let deferredCleanupHandoff = deferredCleanupStore.prepare(
        ClipboardPayload(items: [.imagePNG(png)])
    )
    assertAttachment(
        deferredCleanupStore.commit(deferredCleanupHandoff, to: deferredCleanupSourcePasteboard),
        "deferred-cleanup fixture commits its generated image"
    )
    let unavailableFileListPasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.attachment-unavailable-file-list.\(UUID().uuidString)")
    )
    unavailableFileListPasteboard.declareTypes(
        [CLIPBOARD_FILENAMES_PASTEBOARD_TYPE],
        owner: nil
    )
    assertAttachment(
        deferredCleanupStore.cleanupUnused(pasteboard: unavailableFileListPasteboard) == 0 &&
            deferredCleanupHandoff.fileURLs.first.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true,
        "an advertised but unavailable filename list safely defers attachment cleanup"
    )

    let unownedCacheDirectory = generatedRoot.appendingPathComponent("do-not-delete", isDirectory: true)
    try? FileManager.default.createDirectory(at: unownedCacheDirectory, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)],
        ofItemAtPath: unownedCacheDirectory.path
    )
    let unownedUUIDDirectory = generatedRoot.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try? FileManager.default.createDirectory(at: unownedUUIDDirectory, withIntermediateDirectories: true)
    try? Data("user cache data".utf8).write(
        to: unownedUUIDDirectory.appendingPathComponent("keep.txt", isDirectory: false)
    )
    try? FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)],
        ofItemAtPath: unownedUUIDDirectory.path
    )
    if let generatedDirectory = mixedFileHandoff.generatedDirectory {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: generatedDirectory.path
        )
    }
    assertAttachment(
        attachmentStore.cleanupUnused(pasteboard: pasteboard) == 0 &&
            FileManager.default.fileExists(atPath: mixedFileHandoff.fileURLs[0].path),
        "clipboard ownership refreshes an old generation instead of expiring it"
    )

    let abandonedEmptyUUIDDirectory = generatedRoot.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try? FileManager.default.createDirectory(
        at: abandonedEmptyUUIDDirectory,
        withIntermediateDirectories: true
    )
    try? FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)],
        ofItemAtPath: abandonedEmptyUUIDDirectory.path
    )
    assertAttachment(
        attachmentStore.cleanupUnused(pasteboard: pasteboard) == 1 &&
            !FileManager.default.fileExists(atPath: abandonedEmptyUUIDDirectory.path) &&
            FileManager.default.fileExists(atPath: mixedFileHandoff.fileURLs[0].path),
        "cleanup reclaims expired empty UUID debris without removing the current clipboard generation"
    )

    let emptyHandoff = attachmentStore.prepare(ClipboardPayload(items: [
        .text("must not escape"),
        .unavailableImage(format: .png, byteCount: 99, reason: .perImageLimit)
    ], legacyText: "must not escape"))
    let unchangedPasteboard = NSPasteboard(name: NSPasteboard.Name("macrowhisper.empty-attachment-handoff.\(UUID().uuidString)"))
    unchangedPasteboard.setString("leave untouched", forType: .string)
    assertAttachment(!attachmentStore.commit(emptyHandoff, to: unchangedPasteboard), "no writable attachments produces no file-list handoff")
    assertAttachment(unchangedPasteboard.string(forType: .string) == "leave untouched", "unavailable attachment never falls back to text or clears clipboard")

    let invalidRawImageHandoff = attachmentStore.prepare(ClipboardPayload(
        items: [.imageTIFF(Data([0x49, 0x49, 0x2a, 0x00]))],
        legacyText: "must not escape"
    ))
    assertAttachment(
        invalidRawImageHandoff.fileURLs.isEmpty &&
            invalidRawImageHandoff.imageNormalizationFailureCount == 1,
        "invalid raw image bytes are diagnosed instead of publishing a broken image file"
    )
    assertAttachment(
        !attachmentStore.commit(invalidRawImageHandoff, to: unchangedPasteboard) &&
            unchangedPasteboard.string(forType: .string) == "leave untouched",
        "invalid raw image data never falls back to text or clears the clipboard"
    )

    pasteboard.clearContents()
    pasteboard.setString("replacement", forType: .string)
    assertAttachment(restartedAttachmentStore.cleanupUnused(pasteboard: pasteboard) == 0, "clipboard replacement does not immediately delete a recent generation after restart")
    assertAttachment(FileManager.default.fileExists(atPath: mixedFileHandoff.fileURLs[0].path), "recent generated images survive clipboard replacement")
    if let generatedDirectory = mixedFileHandoff.generatedDirectory {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: generatedDirectory.path
        )
    }
    assertAttachment(restartedAttachmentStore.cleanupUnused(pasteboard: pasteboard) == 1, "expired unreferenced attachment generation is removed after restart")
    assertAttachment(!FileManager.default.fileExists(atPath: mixedFileHandoff.fileURLs[0].path), "expired generated images are removed")
    assertAttachment(FileManager.default.fileExists(atPath: unownedCacheDirectory.path), "cleanup ignores cache directories without a Macrowhisper generation identifier")
    assertAttachment(FileManager.default.fileExists(atPath: unownedUUIDDirectory.path), "cleanup preserves nonempty UUID directories without a Macrowhisper ownership marker")
    assertAttachment((try? Data(contentsOf: borrowedFile)) == borrowedData, "cleanup never removes or modifies borrowed user files")

    let staleReferenceRoot = materializationRoot.appendingPathComponent("stale-reference", isDirectory: true)
    let staleReferenceStore = ClipboardAttachmentFileStore(rootDirectory: staleReferenceRoot)
    let staleReferencePasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.attachment-stale-reference.\(UUID().uuidString)")
    )
    let staleReferenceHandoff = staleReferenceStore.prepare(
        ClipboardPayload(items: [.imagePNG(png)])
    )
    assertAttachment(
        staleReferenceStore.commit(staleReferenceHandoff, to: staleReferencePasteboard),
        "stale-reference fixture commits its generated image"
    )
    if let staleDirectory = staleReferenceHandoff.generatedDirectory,
       let staleFile = staleReferenceHandoff.fileURLs.first {
        try? FileManager.default.removeItem(at: staleFile)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: staleDirectory.path
        )
    }
    assertAttachment(
        staleReferenceStore.cleanupUnused(pasteboard: staleReferencePasteboard) == 1 &&
            staleReferenceHandoff.generatedDirectory.map {
                !FileManager.default.fileExists(atPath: $0.path)
            } == true,
        "a clipboard path to a missing generated file does not preserve stale cache debris"
    )

    let revalidationRoot = materializationRoot.appendingPathComponent("revalidation", isDirectory: true)
    let revalidationStore = ClipboardAttachmentFileStore(rootDirectory: revalidationRoot)
    let revalidationPasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.attachment-revalidation.\(UUID().uuidString)")
    )
    let revalidationHandoff = revalidationStore.prepare(
        ClipboardPayload(items: [.imagePNG(png)])
    )
    assertAttachment(
        revalidationStore.commit(revalidationHandoff, to: revalidationPasteboard),
        "cleanup-revalidation fixture commits its generated image"
    )
    if let revalidationDirectory = revalidationHandoff.generatedDirectory {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: revalidationDirectory.path
        )
    }
    assertAttachment(
        revalidationStore.cleanupUnused(
            preserving: revalidationHandoff.fileURLs,
            validateBeforeRemoval: { false }
        ) == 0 &&
            revalidationHandoff.generatedDirectory.flatMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            } == Date(timeIntervalSince1970: 0),
        "cleanup revalidation does not refresh retention from a stale clipboard snapshot"
    )
    revalidationPasteboard.clearContents()
    revalidationPasteboard.setString("replacement", forType: .string)
    if let revalidationDirectory = revalidationHandoff.generatedDirectory {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: revalidationDirectory.path
        )
    }
    assertAttachment(
        revalidationStore.cleanupUnused(
            preserving: [],
            validateBeforeRemoval: { false }
        ) == 0 &&
            revalidationHandoff.generatedDirectory.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true,
        "cleanup revalidation cancels deletion when clipboard ownership may have changed"
    )
    assertAttachment(
        revalidationStore.cleanupUnused(preserving: []) == 1,
        "an unchanged cleanup pass later removes the expired generation"
    )

    let capacityRoot = materializationRoot.appendingPathComponent("capacity", isDirectory: true)
    let capacityStore = ClipboardAttachmentFileStore(
        rootDirectory: capacityRoot,
        retentionInterval: 24 * 60 * 60,
        maxCacheBytes: Int64(png.count)
    )
    let capacityPasteboard = NSPasteboard(
        name: NSPasteboard.Name("macrowhisper.attachment-capacity.\(UUID().uuidString)")
    )
    let olderCapacityHandoff = capacityStore.prepare(
        ClipboardPayload(items: [.imagePNG(png)])
    )
    assertAttachment(
        capacityStore.commit(olderCapacityHandoff, to: capacityPasteboard),
        "cache-capacity fixture commits its older generation"
    )
    let newerCapacityHandoff = capacityStore.prepare(
        ClipboardPayload(items: [.imagePNG(png)])
    )
    assertAttachment(
        capacityStore.commit(newerCapacityHandoff, to: capacityPasteboard),
        "cache-capacity fixture commits its current generation"
    )
    assertAttachment(
        capacityStore.cleanupUnused(pasteboard: capacityPasteboard) == 1,
        "cache-size cleanup removes the oldest unreferenced generation"
    )
    assertAttachment(
        !FileManager.default.fileExists(atPath: olderCapacityHandoff.fileURLs[0].path) &&
            FileManager.default.fileExists(atPath: newerCapacityHandoff.fileURLs[0].path),
        "cache-size cleanup preserves the generation referenced by the clipboard"
    )

    assertAttachment(writeClipboardOriginalSnapshot(original, to: pasteboard), "representation-aware original snapshot writes successfully")
    assertAttachment(pasteboard.pasteboardItems?.count == 2, "original restoration preserves pasteboard item order")
    assertAttachment(
        pasteboard.pasteboardItems?.first?.string(forType: .fileURL) == fileURL.absoluteString &&
            pasteboard.pasteboardItems?.first?.data(forType: .png) == png &&
            pasteboard.pasteboardItems?.last?.data(forType: .tiff) == tiff,
        "original restoration preserves file URL, PNG, and TIFF representations"
    )

    pasteboard.clearContents()
    pasteboard.setString("do not replace", forType: .string)
    assertAttachment(!writeClipboardOriginalSnapshot(droppedOriginal, to: pasteboard), "incomplete original snapshot refuses partial restoration")
    assertAttachment(pasteboard.string(forType: .string) == "do not replace", "failed oversized restoration leaves the current clipboard untouched")
}

@main
struct ClipboardAttachmentsRegressionRunner {
    static func main() {
        runClipboardAttachmentsRegression()
    }
}
