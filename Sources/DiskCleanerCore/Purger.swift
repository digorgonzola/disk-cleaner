import Darwin
import Foundation

/// Takes deletion off the critical path. `stage` moves a folder into a purge area with a
/// single rename, which is instant on the same volume, so the folder leaves its place at
/// once. `purge` then deletes staged folders, at most `width` at a time.
///
/// Measured on a real pnpm node_modules (APFS): 4 parallel deletes were 1.6x faster than one,
/// and 8 or 16 were slower than 4. Folders left in the purge area by a stopped clean or a
/// crash are deleted by `purgeLeftovers`.
public struct Purger: Sendable {
    public static let defaultWidth = 4

    public let root: String
    private let limiter: AsyncLimiter

    public init(homePath: String = NSHomeDirectory(), width: Int = Purger.defaultWidth) {
        root = homePath + "/Library/Caches/local.disk-cleaner/purge"
        limiter = AsyncLimiter(width: width)
    }

    /// Extended attribute that holds the original path of a staged folder that must go back
    /// if the app stops before its delete is confirmed (a crash before `git worktree remove`).
    static let originAttribute = "local.disk-cleaner.origin"

    /// Moves `path` into the purge area.
    /// - Parameter keepOrigin: Record the original path on the staged folder, so a crash before
    ///   `confirmDelete` leads `recoverLeftovers` to move it back instead of deleting it.
    /// - Returns: The staged path, or `nil` when `path` is on another volume, where a rename
    ///   is not possible. The caller then purges `path` in place.
    /// - Throws: `CleanError.deleteFailed` when the rename fails for another reason.
    public func stage(_ path: String, keepOrigin: Bool = false) throws -> String? {
        // The UUID alone: appending the original name can pass the 255-byte name limit.
        let staged = root + "/" + UUID().uuidString
        var code: Int32 = 0
        // Two tries: the launch cleanup can remove an empty purge area between the two calls.
        for _ in 0..<2 {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            if Darwin.rename(path, staged) == 0 {
                if keepOrigin { Purger.setOrigin(path, on: staged) }
                return staged
            }
            code = errno
            guard code == ENOENT, FileManager.default.fileExists(atPath: path) else { break }
        }
        if code == EXDEV { return nil }
        throw CleanError.deleteFailed(path: path, reason: String(cString: strerror(code)))
    }

    /// Marks a staged folder as safe to delete: removes its recorded original path.
    public func confirmDelete(_ staged: String) {
        _ = removexattr(staged, Purger.originAttribute, XATTR_NOFOLLOW)
    }

    /// Clears the purge area after a crash: a folder with a recorded origin whose parent still
    /// exists goes back, and everything else is deleted.
    /// - Returns: The paths that could not be deleted or moved back, with the reason.
    public func recoverLeftovers() async -> [(path: String, reason: String)] {
        var failures: [(String, String)] = []
        for staged in leftovers() {
            if let origin = Purger.origin(of: staged),
               FileManager.default.fileExists(atPath: (origin as NSString).deletingLastPathComponent),
               (try? restore(staged, to: origin)) != nil {
                continue
            }
            do {
                try await purge(staged)
            } catch {
                failures.append((staged, error.localizedDescription))
            }
        }
        removeAreaIfEmpty()
        return failures
    }

    private static func setOrigin(_ origin: String, on staged: String) {
        let bytes = Array(origin.utf8)
        _ = setxattr(staged, originAttribute, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    }

    static func origin(of staged: String) -> String? {
        let size = getxattr(staged, originAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(staged, originAttribute, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Deletes a folder, waiting for a free slot first.
    /// - Throws: `CancellationError` when the task is cancelled before the delete starts, and
    ///   `CleanError.deleteFailed` when the file system refuses the delete.
    public func purge(_ path: String) async throws {
        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            throw CancellationError()
        }
        let result = await runBlocking { Result { try Purger.removeTree(path) } }
        await limiter.release()
        try result.get()
    }

    /// Moves a staged folder back to where it came from.
    /// - Throws: `CleanError.deleteFailed` when the rename fails, for example because something
    ///   now exists at `original` or its parent is gone.
    public func restore(_ staged: String, to original: String) throws {
        // RENAME_EXCL: never replace something that now exists at the original path.
        guard renamex_np(staged, original, UInt32(RENAME_EXCL)) == 0 else {
            throw CleanError.deleteFailed(path: original, reason: "could not move it back: " + String(cString: strerror(errno)))
        }
    }

    /// Removes the purge area itself once it is empty, so it only shows up in a scan (as a
    /// "Review manually" item) while something in it could not be deleted.
    public func removeAreaIfEmpty() {
        _ = Darwin.rmdir(root)
    }

    /// Paths in the purge area left by an earlier clean that did not finish.
    public func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).map { root + "/" + $0 }
    }

    /// - Throws: `CleanError.deleteFailed` when the tree cannot be removed.
    static func removeTree(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            // Go's module cache and some tool caches are read-only; make them writable and retry.
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+w", path]
            try? chmod.run()
            chmod.waitUntilExit()
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                throw CleanError.deleteFailed(path: path, reason: error.localizedDescription)
            }
        }
    }
}
