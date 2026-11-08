#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(ucrt)
import ucrt
#endif
import Foundation

/// The n72 read-only NAND image consumed by QEMU's FMSS controller.
public enum PackedNAND {
    public enum Failure: Error { case invalidRecord, invalidImage, checksum }

    /// Directory stores retain their existing boot path. A regular file must
    /// carry the exact packed n72 integrity record before it can reach QEMU.
    /// Import verifies the complete digest; boot can recheck bounded structure
    /// after the immutable base has already passed import admission.
    @discardableResult public static func verify(base: URL, verifyDigest: Bool = true) throws -> Bool {
        let nand = base.appendingPathComponent("nand")
        var info = stat()
        guard lstat(nand.path, &info) == 0 else { throw Failure.invalidImage }
        if UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) { return false }
        guard UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG), info.st_nlink == 1,
            let lock = try DeviceLock.read(base: base), lock.board == "n72ap",
            let record = lock.other["outputs"]?["nand"], record["path"]?.string == "nand",
            record["format"]?.string == "ITNAND01", record["listing_sha256"] == nil,
            let pages = record["pages"]?.int, (0...2_097_152).contains(pages),
            let digest = record["sha256"]?.string, validDigest(digest),
            let provenance = record["source_listing_sha256"]?.string, validDigest(provenance)
        else { throw Failure.invalidRecord }
        let fd = open(nand.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidImage }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        var held = stat()
        guard fstat(fd, &held) == 0, held.st_ino == info.st_ino, held.st_dev == info.st_dev,
            held.st_size == 24 + 8 * 1024 * 1024 + Int64(pages) * 4160
        else { throw Failure.invalidImage }
        var hash = SHA256()
        func read(_ count: Int) throws -> Data {
            try Task.checkCancellation()
            var bytes = Data()
            while bytes.count < count {
                guard let block = try source.read(upToCount: count - bytes.count), !block.isEmpty else {
                    throw Failure.invalidImage
                }
                bytes.append(block)
            }
            if verifyDigest { hash.update(data: bytes) }
            return bytes
        }
        func u32(_ bytes: Data, _ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        let header = try read(24)
        guard header.prefix(8) == Data("ITNAND01".utf8),
            u32(header, 8) == 4096, u32(header, 12) == 64,
            u32(header, 16) == 4, u32(header, 20) == 524288
        else { throw Failure.invalidImage }
        var seen = [UInt8](repeating: 0, count: (pages + 7) / 8)
        var referenced = 0
        for _ in 0..<(8 * 1024 * 1024 / 65536) {
            let index = try read(65536)
            try index.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: index.count, by: 4) {
                    let record = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    guard record <= pages else { throw Failure.invalidImage }
                    if record == 0 { continue }
                    let bit = record - 1, mask = UInt8(1 << (bit % 8))
                    guard seen[bit / 8] & mask == 0 else { throw Failure.invalidImage }
                    seen[bit / 8] |= mask
                    referenced += 1
                }
            }
        }
        guard referenced == pages else { throw Failure.invalidImage }
        if verifyDigest {
            var remaining = pages * 4160
            while remaining > 0 {
                let count = min(remaining, 1024 * 1024)
                _ = try read(count); remaining -= count
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest.lowercased() else {
                throw Failure.checksum
            }
        }
        guard try source.seekToEnd() == UInt64(held.st_size) else { throw Failure.invalidImage }
        return true
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
