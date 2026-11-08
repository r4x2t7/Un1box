// PreparedBase: a `create` output packed for the app bundle (the built-in iPod), and unpacked into a device of its
// own.
//
//   try PreparedBase.pack(base: dir, to: itbase, reuse: previous)          // the release build (vendor)
//   try PreparedBase.unpack(itbase, into: staging) { fraction in ... }    // the app's first launch, via firmwarekit
//   try PreparedBase.reseed(staging, seed: uuid)                          // then a unit identity of its own
//   try await PreparedBase.seedLanguage(staging, tag: nil, keyboards: nil) // and the Mac's language
//
// The packed base is a directory, so a rebuild changes only the files whose content changed and Sparkle's per-file
// delta stays small:
//
//   index.json              format 2, sorted keys: every file (name, size, mode, sha256) and every NAND image's
//                           chunks (the sha256 of each 1 MiB of the raw image that is not all zero)
//   files/<name>            each file outside a NAND image, whole (the lock, identity, NOR, geometry.json ...)
//   <image>/<NNNNNN>.z      chunk N of an image (nand/csK.pages -> nand/csK/), zlib-compressed on its own; an
//                           all-zero chunk (a hole: blank NAND) has no file
//
// Nothing in it depends on when or where it was built: the lock is packed without its creation date and with the
// build machine's paths reduced to their last component, and `reuse` (the previous build's packed base) supplies
// every chunk whose raw bytes are unchanged, so a different zlib on the building Mac rewrites nothing. The notary sees
// zlib streams, never the armv6 Mach-Os a volume's pages hold.
//
// reseed gives the base the identity `create --seed` would have: only identity.json, the NOR's SysCfg and nvram, and
// the lock's identity, machine and nor hash depend on the seed (the n72 volume and store don't), so the result is that
// create's output. seedLanguage then gives its volume the language, region and keyboards create seeds from the Mac: the
// release packs a base prepared in en-US whatever the building Mac's.

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
import HostRuntime
import zlib

public enum PreparedBase {
    static let chunk = 1 << 20
    static let format = 2

    struct Index: Codable, Equatable {
        struct File: Codable, Equatable { var name: String, size: Int, mode: Int, sha256: String }
        /// A NAND image: its chunks by number ("000123"), each the sha256 of its raw bytes.
        struct Image: Codable, Equatable { var name: String, size: Int, mode: Int, chunks: [String: String] }
        var format: Int
        var chunkBytes: Int
        var files: [File]
        var images: [Image]

        static func read(_ itbase: URL) throws -> Index {
            guard let data = try? Data(contentsOf: itbase.appendingPathComponent("index.json")),
                let index = try? JSONDecoder().decode(Index.self, from: data), index.format == PreparedBase.format,
                index.chunkBytes == PreparedBase.chunk
            else { throw invalid(itbase, "not a packed device") }
            for name in index.files.map(\.name) + index.images.map(\.name)
            where name.hasPrefix("/") || name.isEmpty
                || name.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                    $0 == ".." || $0.isEmpty || $0 == "."
                })
            {
                throw invalid(itbase, "bad entry \(name)")
            }
            return index
        }

        var data: Data {
            get throws {
                let e = JSONEncoder()
                e.outputFormatting = [.sortedKeys, .prettyPrinted]
                return try e.encode(self)
            }
        }
    }

    static func invalid(_ itbase: URL, _ why: String) -> FirmwareError {
        FirmwareError(.unsupported, "\(itbase.lastPathComponent): \(why)")
    }

    /// Where an image's chunk lives in the packed base: nand/cs0.pages's 123rd is nand/cs0/000123.z.
    static func chunkPath(_ image: String, _ number: String) -> String {
        "\((image as NSString).deletingPathExtension)/\(number).z"
    }

    static func number(_ i: Int) -> String { String(format: "%06d", i) }

    static func isImage(_ name: String) -> Bool { name.hasPrefix("nand/") && name.hasSuffix(".pages") }

    // MARK: - Pack

    /// Every regular file under `base` (sorted; .DS_Store skipped) into the directory `out` (replaced). `reuse`: a
    /// previous build's packed base, whose chunk files are taken as they are wherever the raw bytes are the same.
    public static func pack(base: URL, to out: URL, reuse: URL? = nil) throws {
        let fm = FileManager.default
        var names: [String] = []
        guard let walk = fm.enumerator(atPath: base.path) else {
            throw FirmwareError(.internal, "can't read \(base.path)")
        }
        while let name = walk.nextObject() as? String {
            if (walk.fileAttributes?[.type] as? FileAttributeType) == .typeRegular,
                (name as NSString).lastPathComponent != ".DS_Store"
            {
                names.append(name)
            }
        }
        names.sort()
        guard names.contains("device.lock.json") else {
            throw FirmwareError(.unsupported, "\(base.path) has no device.lock.json")
        }
        let previous = reuse.flatMap { try? Index.read($0) }
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.createDirectory(at: out.appendingPathComponent("files"), withIntermediateDirectories: true)
        var index = Index(format: format, chunkBytes: chunk, files: [], images: [])
        for name in names {
            let url = base.appendingPathComponent(name)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? Int ?? 0o644) & 0o777
            if isImage(name) {
                let size = attributes[.size] as? Int ?? 0
                let chunks = try packImage(
                    url,
                    size: size,
                    into: out.appendingPathComponent((name as NSString).deletingPathExtension),
                    reuse: reuse.map { ($0, previous?.images.first { $0.name == name }?.chunks ?? [:], name) }
                )
                index.images.append(.init(name: name, size: size, mode: mode, chunks: chunks))
                continue
            }
            let data = name == "device.lock.json" ? try scrubbedLock(Data(contentsOf: url)) : try Data(contentsOf: url)
            let dest = out.appendingPathComponent("files/\(name)")
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            index.files.append(.init(name: name, size: data.count, mode: mode, sha256: Preparer.sha256(data)))
        }
        try index.data.write(to: out.appendingPathComponent("index.json"))
    }

    /// The image's non-zero chunks, each compressed into `dir`/NNNNNN.z (or cloned from `reuse` when its raw sha256
    /// is the one recorded there); returns their raw hashes by number.
    static func packImage(_ url: URL, size: Int, into dir: URL, reuse: (URL, [String: String], String)?) throws
        -> [String: String]
    {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        // only chunks holding data are read (SEEK_DATA); an all-zero one among them is still skipped below
        let count = (size + chunk - 1) / chunk
        let candidates = K48NANDImage.dataBlocks(fd, blockBytes: chunk).filter { $0 < count }.sorted()
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var hashes: [String: String] = [:]
            var error: Error?
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
            let i = candidates[k]
            do {
                let length = min(chunk, size - i * chunk)
                var raw = [UInt8](repeating: 0, count: length)
                let got = raw.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(i * chunk)) }
                guard got == length else { throw FirmwareError(.internal, "\(url.path): short read") }
                guard raw.contains(where: { $0 != 0 }) else { return }
                let hash = Preparer.sha256(Data(raw))
                let file = dir.appendingPathComponent("\(number(i)).z")
                if let (previous, chunks, name) = reuse, chunks[number(i)] == hash {
                    let source = previous.appendingPathComponent(chunkPath(name, number(i)))
                    guard copyfile(source.path, file.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                        throw FirmwareError(.internal, "copy \(source.path): \(String(cString: strerror(errno)))")
                    }
                } else {
                    try deflate(raw).write(to: file)
                }
                results.lock.withLock { results.hashes[number(i)] = hash }
            } catch { results.lock.withLock { results.error = results.error ?? error } }
        }
        if let error = results.error { throw error }
        return results.hashes
    }

    static func deflate(_ raw: [UInt8]) throws -> Data {
        var size = compressBound(uLong(raw.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&out, &size, raw, uLong(raw.count), 6) == Z_OK else {
            throw FirmwareError(.internal, "deflate")
        }
        return Data(out.prefix(Int(size)))
    }

    /// The lock without its creation date and with the host paths `create` records (its IPSW, decrypt cache, guest
    /// tools, helper, guest package) reduced to their last component: nothing reads them back, and a shipped base names
    /// no build machine and changes only when its content does.
    static func scrubbedLock(_ data: Data) throws -> Data {
        guard var lock = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FirmwareError(.unsupported, "device.lock.json is not an object")
        }
        lock.removeValue(forKey: "created")
        func name(_ value: Any?) -> Any { (value as? String).map { ($0 as NSString).lastPathComponent } ?? NSNull() }
        if var inputs = lock["inputs"] as? [String: Any] {
            if var ipsw = inputs["ipsw"] as? [String: Any] {
                ipsw["path"] = name(ipsw["path"])
                inputs["ipsw"] = ipsw
            }
            for key in ["decrypted", "guest_tools"] where inputs[key] != nil { inputs[key] = name(inputs[key]) }
            lock["inputs"] = inputs
        }
        if var tool = lock["tool"] as? [String: Any], tool["helper"] != nil {
            tool["helper"] = name(tool["helper"])
            lock["tool"] = tool
        }
        if var package = lock["guest_package"] as? [String: Any], var itpack = package["itpack"] as? [String: Any] {
            itpack["path"] = name(itpack["path"])
            package["itpack"] = itpack
            lock["guest_package"] = package
        }
        return try DeviceLock(json: lock).data()
    }

    // MARK: - Unpack

    /// Unpacks `itbase` into `directory` (created), reporting the fraction done as it goes. Nothing outside `directory`
    /// is written: a name that leaves it is refused before any file is made. Every file and chunk is checked against
    /// its sha256. Packed modes are set once each file is complete; nand/ and its directories end read-only, as create
    /// leaves them.
    public static func unpack(_ itbase: URL, into directory: URL, progress: (Double) throws -> Void = { _ in }) throws {
        let fm = FileManager.default
        let index = try Index.read(itbase)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = Double(index.files.count + index.images.reduce(0) { $0 + $1.chunks.count })
        var done = 0.0
        try progress(0)
        for f in index.files {
            let data = try Data(contentsOf: itbase.appendingPathComponent("files/\(f.name)"))
            guard data.count == f.size, Preparer.sha256(data) == f.sha256 else {
                throw invalid(itbase, "\(f.name) differs from its index")
            }
            let url = directory.appendingPathComponent(f.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            chmod(url.path, mode_t(f.mode))
            done += 1
        }
        for image in index.images {
            let url = directory.appendingPathComponent(image.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0, ftruncate(fd, off_t(image.size)) == 0 else {
                throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))")
            }
            defer { close(fd) }
            // in batches, so the progress moves while the chunks inflate in parallel
            let chunks = image.chunks.sorted { $0.key < $1.key }
            for batch in Swift.stride(from: 0, to: chunks.count, by: 64) {
                let slice = Array(chunks[batch..<min(batch + 64, chunks.count)])
                try inflateChunks(slice, of: image, from: itbase, into: fd)
                done += Double(slice.count)
                try progress(done / max(total, 1))
            }
            guard fsync(fd) == 0 else {
                throw FirmwareError(.internal, "\(url.path): \(String(cString: strerror(errno)))")
            }
            chmod(url.path, mode_t(image.mode))
        }
        let nand = directory.appendingPathComponent("nand")
        if fm.fileExists(atPath: nand.path) { try Preparer.readOnly(nand) }
        try progress(1)
    }

    static func inflateChunks(
        _ chunks: [(key: String, value: String)],
        of image: Index.Image,
        from itbase: URL,
        into fd: Int32
    )
        throws
    {
        final class Failure: @unchecked Sendable {
            let lock = NSLock()
            var error: Error?
        }
        let failure = Failure()
        DispatchQueue.concurrentPerform(iterations: chunks.count) { k in
            do {
                let (number, hash) = chunks[k]
                guard let i = Int(number), i >= 0, i * chunk < image.size else {
                    throw invalid(itbase, "\(image.name) chunk \(number) is outside the image")
                }
                let packed = [UInt8](try Data(contentsOf: itbase.appendingPathComponent(chunkPath(image.name, number))))
                let length = min(chunk, image.size - i * chunk)
                var raw = [UInt8](repeating: 0, count: length)
                var size = uLong(length)
                guard uncompress(&raw, &size, packed, uLong(packed.count)) == Z_OK, size == length,
                    Preparer.sha256(Data(raw)) == hash
                else { throw invalid(itbase, "\(image.name) chunk \(number) is damaged") }
                let n = raw.withUnsafeBytes { pwrite(fd, $0.baseAddress, length, off_t(i * chunk)) }
                guard n == length else {
                    throw FirmwareError(errno == ENOSPC ? .diskFull : .internal, String(cString: strerror(errno)))
                }
            } catch { failure.lock.withLock { failure.error = failure.error ?? error } }
        }
        if let error = failure.error { throw error }
    }

    // MARK: - Identity

    /// Gives an unpacked n72 base the unit identity `create --seed seed` makes: identity.json, the NOR's SysCfg and
    /// nvram, and the lock's identity, machine and nor hash. Other boards' identities reach their volumes; refused.
    public static func reseed(_ base: URL, seed: String) throws {
        let fm = FileManager.default
        let lockURL = base.appendingPathComponent("device.lock.json")
        let identityURL = base.appendingPathComponent("identity.json")
        let norURL = base.appendingPathComponent("nor.bin")
        guard var lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any] else {
            throw FirmwareError(.unsupported, "device.lock.json is not an object")
        }
        guard lock["board"] as? String == "n72ap" else {
            throw FirmwareError(.unsupported, "only an n72ap base takes a new identity, not \(lock["board"] ?? "?")")
        }
        let old = try UnitIdentity.load(from: identityURL)
        guard let model = old["model-number"], let region = old["region-info"] else {
            throw FirmwareError(.unsupported, "identity.json has no model or region")
        }
        let id = try UnitIdentity.synthesizeIPod(seed: seed, modelNumber: model, regionInfo: region)
        try fm.removeItem(at: identityURL)
        try id.write(to: identityURL)
        let nor = try N72NOR.reidentify(Data(contentsOf: norURL), identity: id)
        let mode = (try fm.attributesOfItem(atPath: norURL.path)[.posixPermissions] as? Int) ?? 0o444
        chmod(norURL.path, 0o644)
        try nor.write(to: norURL)
        chmod(norURL.path, mode_t(mode))
        lock["identity"] = ["seed": seed, "udid": id.udid ?? "", "sha256": try Preparer.digest(identityURL, SHA256())]
        var machine = lock["machine"] as? [String: Any] ?? [:]
        machine["wifi-mac"] = id["wifi-mac"]
        machine["bt-mac"] = id["bt-mac"]
        machine["ecid"] = id["unique-chip-id"]
        lock["machine"] = machine
        if var outputs = lock["outputs"] as? [String: Any], var record = outputs["nor"] as? [String: Any] {
            record["sha256"] = Preparer.sha256(nor)
            outputs["nor"] = record
            lock["outputs"] = outputs
        }
        try DeviceLock(json: lock).data().write(to: lockURL, options: .atomic)
    }

    /// Seeds the language, region and keyboards (SystemEdits.seedLanguage: `tag`, else the Mac's; `keyboards`, else
    /// the Mac's enabled ones) into the n72 base's system volume, which keeps /private/var, as create does: the volume
    /// rebuilt from the store, edited, and laid out again as a fresh store (N72NAND.write), the lock's NAND record and
    /// derived language with it.
    nonisolated public static func seedLanguage(_ base: URL, tag: String?, keyboards: [String]?)
        async throws
    {
        let fm = FileManager.default
        let lockURL = base.appendingPathComponent("device.lock.json")
        let nand = base.appendingPathComponent("nand")
        guard var lock = try JSONSerialization.jsonObject(with: Data(contentsOf: lockURL)) as? [String: Any] else {
            throw FirmwareError(.unsupported, "device.lock.json is not an object")
        }
        // a store N72Recipe did not lay out (the app's test fixtures) has no volume to seed
        guard var derived = lock["derived"] as? [String: Any], let epoch = derived["nand_epoch"] as? Int else { return }
        let work = base.appendingPathComponent("language-work")
        try? fm.removeItem(at: work)
        defer { try? fm.removeItem(at: work) }
        guard let image = try VolumeRebuild.rebuild(base: nand, overlay: nil, into: work, only: ["system"]).first?.image
        else { throw FirmwareError(.unsupported, "the base has no system volume") }
        let seeded = try await VolumeMount.withMounted(image, at: work.appendingPathComponent("mnt")) { m in
            try SystemEdits.seedLanguage(
                m.appendingPathComponent("private/var"),
                tag: tag,
                keyboards: keyboards,
                catalog: SystemEdits.KeyboardCatalog(m.appendingPathComponent("System/Library/TextInput")),
                formats: SystemEdits.regionFormats(m)
            )
        }
        guard let seeded else { return }
        let hfs = try HFSPlusVolume(image)
        chmod(nand.path, 0o755)  // unpacked read-only, as create leaves it
        try fm.removeItem(at: nand)
        try N72NAND.write(
            volume: image,
            blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page,
            epoch: epoch,
            out: nand
        )
        try Preparer.readOnly(nand)
        let files = try Recipe.nandFiles(nand)
        let listing = try Preparer.nandListing(nand, files: files)
        var outputs = lock["outputs"] as? [String: Any] ?? [:]
        var record = outputs["nand"] as? [String: Any] ?? ["path": "nand"]
        record["pages"] = files.count
        record["listing_sha256"] = listing.sha256
        record["built_listing_sha256"] = listing.sha256
        outputs["nand"] = record
        lock["outputs"] = outputs
        derived["language"] = "\(seeded.language), region \(seeded.locale), keyboards \(seeded.keyboards)"
        lock["derived"] = derived
        try DeviceLock(json: lock).data().write(to: lockURL, options: .atomic)
    }
}
