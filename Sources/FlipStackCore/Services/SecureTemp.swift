import Foundation

/// Creates and writes the temporary files FlipStack derives from user
/// documents (selected-page extracts, scaled copies, imposed booklets,
/// calibration sheets) with permissions set at creation time. Setting 0700
/// only after creation leaves a world-traversable window, and `$TMPDIR` is
/// only protected when FlipStack never weakens it.
public enum SecureTemp {
    /// `$TMPDIR/FlipStack/<prefix>-<uuid>`. Both the `FlipStack` parent and
    /// the leaf directory are created (or re-tightened) with 0700.
    @discardableResult
    public static func makeDirectory(prefix: String, parentName: String = "FlipStack") throws -> URL {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent(parentName, isDirectory: true)
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        let directory = parent
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// Makes sure the parent directory of `url` exists with 0700, without
    /// replacing a caller-provided working directory.
    public static func secureParent(of url: URL) throws {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
    }

    /// Writes `data` to `url` with 0600 applied at creation, replacing any
    /// existing file. `FileManager.createFile` sets the attributes as part of
    /// creation, so the content is never exposed with default permissions.
    public static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
