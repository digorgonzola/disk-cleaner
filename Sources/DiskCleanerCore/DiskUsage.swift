import Darwin
import Foundation

public struct Usage: Sendable, Equatable {
    public let bytes: Int64
    /// Newest modification time of anything inside the folder.
    public let lastModified: Date?
    /// Paths, relative to the folder, of files the rule says must not be deleted.
    public var protectedFiles: [String] = []
}

public enum DiskUsage {
    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// Allocated size on disk, like `du -sk`: counts real blocks (sparse VM images report
    /// their true footprint), counts each hard link once, and stays on one volume.
    /// APFS clones still count in full because the file system does not expose sharing.
    /// Files named in `protectedNames` are reported in `protectedFiles`, unless they sit in a
    /// `.terraform` folder, where `terraform.tfstate` is only backend settings, not state.
    public static func usage(of path: String, protectedNames: Set<String> = []) -> Usage {
        var protected: [String] = []
        var seenLinks = Set<FileID>()
        var bytes: Int64 = 0
        var newest: timespec?

        let pathCopy = strdup(path)
        defer { free(pathCopy) }
        var argv: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return Usage(bytes: 0, lastModified: nil)
        }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            // FTS_DP is the post-order visit of a folder already counted as FTS_D.
            guard info != FTS_DP, info != FTS_DNR, info != FTS_ERR, info != FTS_NS,
                  let stat = entry.pointee.fts_statp?.pointee
            else { continue }

            if info == FTS_F, !protectedNames.isEmpty {
                let entryPath = String(cString: entry.pointee.fts_path)
                let name = (entryPath as NSString).lastPathComponent
                if protectedNames.contains(name), !entryPath.contains("/.terraform/") {
                    protected.append(String(entryPath.dropFirst(path.count + 1)))
                }
            }
            if info != FTS_D, stat.st_nlink > 1 {
                guard seenLinks.insert(FileID(device: stat.st_dev, inode: stat.st_ino)).inserted else { continue }
            }
            bytes += Int64(stat.st_blocks) * 512
            if let current = newest {
                if stat.st_mtimespec.tv_sec > current.tv_sec { newest = stat.st_mtimespec }
            } else {
                newest = stat.st_mtimespec
            }
        }

        let date = newest.map { Date(timeIntervalSince1970: TimeInterval($0.tv_sec)) }
        return Usage(bytes: bytes, lastModified: date, protectedFiles: protected)
    }

    public struct VolumeSpace: Sendable, Equatable {
        public let total: Int64
        public let available: Int64
    }

    /// Space on the volume that holds `path`. "Available" includes purgeable space,
    /// which matches the number Finder shows.
    public static func volumeSpace(for path: String = NSHomeDirectory()) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return VolumeSpace(total: Int64(total), available: available)
    }
}
