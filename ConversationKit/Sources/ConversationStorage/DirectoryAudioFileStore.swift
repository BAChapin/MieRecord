import ConversationCore
import Foundation

/// Stores recording audio under a single app-managed directory.
///
/// Default location is `Application Support/Recordings`, which is backed up and
/// not purged by the system. Files are created with complete file protection
/// until first user authentication so audio at rest is encrypted while the
/// device is locked after a reboot, yet background recording can keep writing.
public struct DirectoryAudioFileStore: AudioFileStore {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// The default store inside Application Support. Creates the directory.
    public static func applicationSupport(fileManager: FileManager = .default) throws -> DirectoryAudioFileStore {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "Recordings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return DirectoryAudioFileStore(directoryURL: directory)
    }

    public func makeFileURL(forRecordingID id: UUID, fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appending(path: "\(id.uuidString).\(fileExtension)")
        #if os(iOS)
        // Pre-create so the protection attribute applies to the file AVAudioFile opens.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        #endif
        return url
    }

    public func url(for reference: AudioFileReference) -> URL {
        directoryURL.appending(path: reference.fileName)
    }

    public func removeFile(for reference: AudioFileReference) throws {
        let url = url(for: reference)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
