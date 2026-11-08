// Stand-ins for Apple-only API when HostRuntime builds for Linux, Android or Windows.
import Foundation
#if canImport(CPortability)
import CPortability
#endif

#if !canImport(os)
/// os.OSAllocatedUnfairLock's state-holding lock, as far as HostRuntime uses it.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(initialState: State) { state = initialState }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif

extension NSNumber {
    /// Whether JSONSerialization made this number from `true` or `false`.
    var isJSONBoolean: Bool {
        #if canImport(Darwin)
        return CFGetTypeID(self) == CFBooleanGetTypeID()
        #else
        return self === NSNumber(value: true) || self === NSNumber(value: false) || String(cString: objCType) == "B"
        #endif
    }

    /// Whether JSONSerialization read this number with a fraction or exponent.
    var isJSONFloat: Bool {
        #if canImport(Darwin)
        return CFNumberIsFloatType(self)
        #else
        let type = String(cString: objCType)
        return type == "d" || type == "f"
        #endif
    }
}

/// chflags(path, 0): clears the user-immutable flag Darwin sets on read-only bases; nothing to clear elsewhere.
func clearFileFlags(_ path: String) -> Int32 {
    #if canImport(Darwin)
    return chflags(path, 0)
    #else
    return 0
    #endif
}

#if !canImport(Darwin)
public typealias copyfile_flags_t = UInt32
public let COPYFILE_CLONE: UInt32 = 1 << 24

/// copyfile(3) with COPYFILE_CLONE: a clone where the filesystem can, else a copy (as Darwin falls back to).
public func copyfile(_ source: String, _ target: String, _ state: OpaquePointer?, _ flags: copyfile_flags_t) -> Int32 {
    clonefile(source, target, 0)
}

/// Darwin's clonefile(2): a file as a reflink where the filesystem has them (btrfs, XFS), else a copy that keeps
/// holes, so a chip file's unwritten blocks stay unallocated; a folder with everything in it; a symlink as itself.
public func clonefile(_ source: String, _ target: String, _ flags: UInt32) -> Int32 {
    var link = stat()
    guard lstat(source, &link) == 0 else { return -1 }
    if UInt32(link.st_mode) & UInt32(S_IFMT) == UInt32(S_IFLNK) {
        guard let to = try? FileManager.default.destinationOfSymbolicLink(atPath: source) else { return -1 }
        return symlink(to, target)
    }
    if UInt32(link.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) {
        // as macOS's: a folder is cloned with everything in it
        guard mkdir(target, mode_t(UInt32(link.st_mode)) & 0o7777 | 0o700) == 0,
            let names = try? FileManager.default.contentsOfDirectory(atPath: source)
        else { return -1 }
        for name in names where clonefile(source + "/" + name, target + "/" + name, flags) != 0 { return -1 }
        return chmod(target, mode_t(UInt32(link.st_mode)) & 0o7777)
    }
    let input = open(source, O_RDONLY)
    guard input >= 0 else { return -1 }
    defer { close(input) }
    var info = stat()
    guard fstat(input, &info) == 0 else { return -1 }
    let output = open(target, O_WRONLY | O_CREAT | O_EXCL, mode_t(UInt32(info.st_mode)) & 0o7777)
    guard output >= 0 else { return -1 }
    defer { close(output) }
    #if os(Linux) || os(Android)
    let FICLONE: UInt = 0x4004_9409
    if ioctl(output, FICLONE, input) == 0 { return 0 }
    #endif
    let size = Int64(info.st_size)
    guard ftruncate(output, off_t(size)) == 0 else { return -1 }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var offset: off_t = 0
    while offset < size {
        #if os(Linux) || os(Android)
        let data = lseek(input, offset, 3)  // SEEK_DATA
        if data < 0 { break }  // ENXIO: only a hole remains
        let hole = lseek(input, data, 4)  // SEEK_HOLE
        #else
        let data = offset, hole = info.st_size
        #endif
        var at = data
        while at < hole {
            let n = pread(input, &buffer, min(buffer.count, Int(hole - at)), at)
            guard n > 0 else { return -1 }
            if buffer[0..<n].contains(where: { $0 != 0 }) {
                guard pwrite(output, buffer, n, at) == n else { return -1 }
            }
            at += off_t(n)
        }
        offset = hole
    }
    return 0
}
#endif

#if !canImport(Darwin)
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// `Darwin.close(fd)` and the like, where code names the C library to step around a same-named member.
public enum Darwin {
    @discardableResult public static func close(_ fd: Int32) -> Int32 { libcClose(fd) }
    public static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { libcOpen(path, flags, mode) }
    public static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ count: Int) -> Int { libcRead(fd, buf, count) }
    public static func write(_ fd: Int32, _ buf: UnsafeRawPointer!, _ count: Int) -> Int { libcWrite(fd, buf, count) }
    public static func send(_ fd: Int32, _ buf: UnsafeRawPointer!, _ count: Int, _ flags: Int32) -> Int {
        libcSend(fd, buf, count, flags)
    }
}

private func libcClose(_ fd: Int32) -> Int32 { close(fd) }
private func libcOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { open(path, flags, mode) }
private func libcRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer!, _ count: Int) -> Int { read(fd, buf, count) }
private func libcWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ count: Int) -> Int { write(fd, buf, count) }
private func libcSend(_ fd: Int32, _ buf: UnsafeRawPointer!, _ count: Int, _ flags: Int32) -> Int { send(fd, buf, count, flags) }
#endif

#if !canImport(Darwin)
/// fcntl's F_FULLFSYNC is Darwin's; elsewhere the call fails (EINVAL), and callers fall back to fsync.
public let F_FULLFSYNC: Int32 = -1

/// BSD file flags (uchg on read-only bases) are Darwin's; elsewhere there are none to set or clear.
public func chflags(_ path: String, _ flags: UInt32) -> Int32 { 0 }

/// Darwin's extended attribute calls (with position and options), used by the Mac's stopped-device edits only;
/// elsewhere they fail with ENOTSUP.
public let XATTR_NOFOLLOW: Int32 = 1
public let ENOATTR: Int32 = ENODATA

public func listxattr(_ path: String, _ names: UnsafeMutablePointer<CChar>?, _ size: Int, _ options: Int32) -> Int {
    errno = ENOTSUP
    return -1
}

public func getxattr(
    _ path: String, _ name: String, _ value: UnsafeMutableRawPointer?, _ size: Int, _ position: UInt32,
    _ options: Int32
) -> Int {
    errno = ENOTSUP
    return -1
}

public func setxattr(
    _ path: String, _ name: String, _ value: UnsafeRawPointer?, _ size: Int, _ position: UInt32, _ options: Int32
) -> Int32 {
    errno = ENOTSUP
    return -1
}
#endif

#if !canImport(Darwin) && !os(Android)
/// lseek's SEEK_DATA and SEEK_HOLE (Linux has them; Glibc's module leaves them out).
public let SEEK_DATA: Int32 = 3
public let SEEK_HOLE: Int32 = 4
#endif

#if !canImport(Darwin)

/// <sys/stat.h>'s UF_IMMUTABLE, for chflags (a no-op off Darwin).
public let UF_IMMUTABLE: UInt32 = 0x2
#endif
