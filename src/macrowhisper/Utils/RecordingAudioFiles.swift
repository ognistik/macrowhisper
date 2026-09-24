import Foundation

enum RecordingAudioFiles {
    private static let supportedExtensions: Set<String> = ["wav", "ogg"]

    static func isSupportedAudioPath(_ path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func hasUsableAudioFile(in directoryPath: String) throws -> Bool {
        let contents = try FileManager.default.contentsOfDirectory(atPath: directoryPath)

        for fileName in contents where isSupportedAudioPath(fileName) {
            let filePath = (directoryPath as NSString).appendingPathComponent(fileName)
            let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
            if let fileSize = attributes?[.size] as? Int64, fileSize > 0 {
                return true
            }
        }

        return false
    }
}
