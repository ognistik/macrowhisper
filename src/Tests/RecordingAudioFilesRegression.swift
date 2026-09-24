import Foundation

private func assertAudio(_ condition: Bool, _ label: String) {
    guard condition else {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

@main
struct RecordingAudioFilesRegressionRunner {
    static func main() throws {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macrowhisper-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        func write(_ name: String, contents: Data) throws {
            try contents.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent(name)))
        }

        assertAudio(try !RecordingAudioFiles.hasUsableAudioFile(in: directory), "empty folder has no audio")
        try write("output.ogg", contents: Data())
        assertAudio(try !RecordingAudioFiles.hasUsableAudioFile(in: directory), "zero-byte OGG is not ready")
        try write("notes.txt", contents: Data([1]))
        assertAudio(try !RecordingAudioFiles.hasUsableAudioFile(in: directory), "unrelated files are ignored")

        try write("output.ogg", contents: Data([1]))
        assertAudio(try RecordingAudioFiles.hasUsableAudioFile(in: directory), "nonempty OGG is recognized")
        try FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent("output.ogg"))
        try write("output.OGG", contents: Data([1]))
        assertAudio(try RecordingAudioFiles.hasUsableAudioFile(in: directory), "OGG extension is case insensitive")

        try write("output.wav", contents: Data([1]))
        try FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent("output.OGG"))
        assertAudio(try RecordingAudioFiles.hasUsableAudioFile(in: directory), "WAV remains recognized")
        try write("output.ogg", contents: Data([1]))
        try FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent("output.wav"))
        assertAudio(try RecordingAudioFiles.hasUsableAudioFile(in: directory), "removing WAV does not cancel while OGG remains")

        assertAudio(RecordingAudioFiles.isSupportedAudioPath("/recordings/123/output.ogg"), "OGG path is normalized as audio")
        assertAudio(RecordingAudioFiles.isSupportedAudioPath("/recordings/123/output.WAV"), "WAV path matching is case insensitive")
    }
}
