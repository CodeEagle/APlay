import Foundation

/// Sweeps before a container is opened, so eviction cannot invalidate its writer.
final class DiskCacheCleaner: @unchecked Sendable {
    private struct File {
        let url: URL
        let size: UInt64
        let modified: TimeInterval
    }

    private struct Entry {
        let files: [File]
        let lastAccess: TimeInterval
    }

    func sweepIfNeeded(cacheDirectory: String, maxSize: UInt64, excluding: [String] = [], log: ((String) -> Void)? = nil) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: cacheDirectory) else { return }
        let directory = URL(fileURLWithPath: cacheDirectory, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileAllocatedSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        } catch {
            log?("Disk cache scan failed: \(error)")
            return
        }

        var files: [String: File] = [:]
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isDirectory != true else { continue }
                // Logical length includes sparse holes and would evict almost-empty downloads.
                guard let allocated = values.fileAllocatedSize else {
                    log?("Disk cache size unavailable: \(url.lastPathComponent)")
                    continue
                }
                files[url.lastPathComponent] = File(url: url, size: UInt64(max(0, allocated)),
                                                    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            } catch {
                log?("Disk cache inspection failed for \(url.lastPathComponent): \(error)")
            }
        }

        // The track whose container is being opened must survive its own sweep.
        let protected: Set<String> = Set(excluding.flatMap { name -> [String] in
            [name, "\(name).part", "\(name).part.meta", "\(name).part.meta.tmp"]
        })

        func remove(_ file: File) -> Bool {
            do {
                try manager.removeItem(at: file.url)
                log?("Disk cache deleted: \(file.url.lastPathComponent)")
                return true
            } catch {
                log?("Disk cache deletion failed for \(file.url.lastPathComponent): \(error)")
                return false
            }
        }

        var entries: [Entry] = []
        var owned: Set<String> = []
        // Group companions first so directory enumeration order cannot orphan a sidecar.
        for (name, file) in files where name.hasSuffix(".part") && !protected.contains(name) {
            var companions = [file]
            var access = file.modified
            for suffix in [".meta", ".meta.tmp"] {
                if let companion = files[name + suffix] {
                    companions.append(companion)
                    owned.insert(name + suffix)
                }
            }
            if let meta = ResumeCacheMeta.load(nextTo: file.url), meta.lastAccess.isFinite {
                access = meta.lastAccess
            }
            // Corrupt sidecars still occupy disk and must disappear with their container.
            entries.append(Entry(files: companions, lastAccess: access))
            owned.insert(name)
        }
        for (name, file) in files where !owned.contains(name) && !protected.contains(name) {
            if name.hasSuffix(".tmp") {
                // Interrupted sequential writes have no reusable progress to preserve.
                _ = remove(file)
            } else {
                entries.append(Entry(files: [file], lastAccess: file.modified))
            }
        }

        var total = entries.reduce(UInt64(0)) { $0 + $1.files.reduce(UInt64(0)) { $0 + $1.size } }
        entries.sort {
            if $0.lastAccess == $1.lastAccess {
                return $0.files[0].url.lastPathComponent < $1.files[0].url.lastPathComponent
            }
            return $0.lastAccess < $1.lastAccess
        }
        for entry in entries {
            guard total > maxSize else { break }
            for file in entry.files {
                // A failed unlink releases no space; continue to later eviction candidates.
                if remove(file) { total -= file.size }
            }
        }
        log?("Disk cache total allocated size: \(total) bytes")
    }
}
