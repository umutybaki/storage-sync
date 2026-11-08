import Darwin
import Foundation
import StorageSyncCore

/// Directory descriptors keep relative operations on the selected directory even
/// if a path component is subsequently replaced with a link.
struct DownloadPartial {
    let directory: FileHandle
    let file: FileHandle
    let name: String
    let sizeAtOpen: Int64

    init(root: URL, transferID: TransferID) throws {
        let parent = try Self.openRoot(root)
        let directory = try Self.openDirectory(ReservedName.partialsDirectory, parent: parent, create: true)
        let name = transferID.description + ".partial"
        let fd = openat(directory.fileDescriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw Self.posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw SafePathError.escapesRoot(name)
        }
        self.directory = directory
        self.file = handle
        self.name = name
        self.sizeAtOpen = info.st_size
    }

    static func remove(_ name: String, beneath root: URL) {
        guard let parent = try? openRoot(root),
              let directory = try? openDirectory(ReservedName.partialsDirectory, parent: parent, create: false) else { return }
        // unlinkat without AT_REMOVEDIR cannot recurse or follow a leaf symlink.
        _ = unlinkat(directory.fileDescriptor, name, 0)
    }

    func publish(relativePath: String, root: URL, replacing: Bool) throws {
        let components = Reconciler.pathComponents(relativePath)
        guard Reconciler.isSafeRelativePath(relativePath), let leaf = components.last else {
            throw SafePathError.invalidRelativePath(relativePath)
        }
        var parent = try Self.openRoot(root)
        for component in components.dropLast() {
            parent = try Self.openDirectory(String(component), parent: parent, create: true)
        }
        var opened = stat()
        var named = stat()
        guard fstat(file.fileDescriptor, &opened) == 0,
              fstatat(directory.fileDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, named.st_nlink == 1 else {
            throw SafePathError.escapesRoot(name)
        }
        if replacing {
            // Preserve the existing destination's access controls on the new inode.
            let old = openat(parent.fileDescriptor, String(leaf), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard old >= 0 else {
                if errno == ENOENT || errno == ELOOP { throw TransferExecutionError.destinationChanged }
                throw Self.posixError()
            }
            defer { close(old) }
            guard fcopyfile(old, file.fileDescriptor, nil, copyfile_flags_t(COPYFILE_SECURITY)) == 0,
                  futimens(file.fileDescriptor, [opened.st_atimespec, opened.st_mtimespec]) == 0 else {
                throw Self.posixError()
            }
        }
        // A file appearing after the final fingerprint must win an absent-path race.
        let result = renameatx_np(directory.fileDescriptor, name, parent.fileDescriptor, String(leaf),
                                  replacing ? 0 : UInt32(RENAME_EXCL))
        guard result == 0 else {
            if !replacing, errno == ENOTSUP {
                // A filesystem may support hard links without supporting exclusive rename.
                if linkat(directory.fileDescriptor, name, parent.fileDescriptor, String(leaf), 0) == 0 {
                    _ = unlinkat(directory.fileDescriptor, name, 0)
                    return
                }
            }
            if errno == EEXIST { throw TransferExecutionError.destinationChanged }
            throw Self.posixError()
        }
    }

    private static func openRoot(_ root: URL) throws -> FileHandle {
        let fd = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func openDirectory(_ name: String, parent: FileHandle, create: Bool) throws -> FileHandle {
        let mode: mode_t = name == ReservedName.partialsDirectory ? 0o700 : 0o755
        if create, mkdirat(parent.fileDescriptor, name, mode) == -1, errno != EEXIST {
            throw posixError()
        }
        let fd = openat(parent.fileDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
