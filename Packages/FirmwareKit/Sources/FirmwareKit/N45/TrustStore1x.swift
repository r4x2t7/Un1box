// iPhone OS 1.x's certificate anchors. 1.0's SecTrust asks only the system anchor source, the trust store in
// Security.framework (table tsettings, the schema 2.x/3.x keep for their user store); the user store
// (~/Library/Keychains/TrustStore.sqlite3) is never consulted. A row there makes a certificate an anchor:
// sha1 of its DER, subj the subject Name's content as 1.x normalizes it (PrintableString values uppercased,
// every other string type as issued, read off the stock rows), tset the stock rows' empty-array plist, data the
// DER. Checked on M68 1A543a: with the row, SecTrustEvaluate gives 4 (unspecified) for a WebProxyCA-shaped
// chain and Safari opens HTTPS through a TLS 1.0 relay; without it, 3 (deny).

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import FirmwareSchema
import Foundation
import HostRuntime
#if canImport(SQLite3)
import SQLite3
#endif

public enum TrustStore1x {
    static let path = "System/Library/Frameworks/Security.framework/TrustStore.sqlite3"
    /// The stock rows' tset: an empty trust-settings array.
    static let emptySettings = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array/>
        </plist>

        """.utf8
    )

    /// A DER element at `o`: (tag, header length, content length).
    private static func element(_ d: [UInt8], _ o: Int) throws -> (tag: UInt8, header: Int, length: Int) {
        guard o + 1 < d.count else { throw FirmwareError(.unsupported, "certificate truncated") }
        var length = Int(d[o + 1])
        var header = 2
        if length & 0x80 != 0 {
            let n = length & 0x7f
            guard n <= 3, o + 2 + n <= d.count else { throw FirmwareError(.unsupported, "certificate length") }
            length = d[(o + 2)..<(o + 2 + n)].reduce(0) { $0 << 8 | Int($1) }
            header = 2 + n
        }
        guard o + header + length <= d.count else { throw FirmwareError(.unsupported, "certificate truncated") }
        return (d[o], header, length)
    }

    /// The certificate's subject Name content, normalized as 1.x stores it.
    static func normalizedSubject(_ certificate: Data) throws -> Data {
        let d = [UInt8](certificate)
        var o = try element(d, 0).header  // Certificate
        o += try element(d, o).header  // TBSCertificate
        if d[o] == 0xa0 {
            let e = try element(d, o)
            o += e.header + e.length
        }  // version
        for _ in 0..<4 {
            let e = try element(d, o)
            o += e.header + e.length
        }  // serial, signature, issuer, validity
        let name = try element(d, o)
        var out = Array(d[(o + name.header)..<(o + name.header + name.length)])
        // Walk the RDNs: SET { SEQUENCE { OID, value } }; uppercase PrintableString (0x13) values in place.
        var p = 0
        while p < out.count {
            let set = try element(out, p)
            var q = p + set.header
            while q < p + set.header + set.length {
                let atv = try element(out, q)
                let oid = try element(out, q + atv.header)
                let v = q + atv.header + oid.header + oid.length
                let value = try element(out, v)
                if value.tag == 0x13 {
                    for i in (v + value.header)..<(v + value.header + value.length) where (0x61...0x7a).contains(out[i])
                    { out[i] -= 0x20 }
                }
                q += atv.header + atv.length
            }
            p += set.header + set.length
        }
        return Data(out)
    }

    /// Adds (or replaces) `certificate` as an anchor in the trust store at `store`.
    static func addAnchor(_ certificate: Data, to store: URL) throws {
        let subject = try normalizedSubject(certificate)
        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FirmwareError(.unsupported, "\(store.path): not a trust store")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "INSERT OR REPLACE INTO tsettings(sha1,subj,tset,data) VALUES(?,?,?,?)",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK
        else { throw FirmwareError(.unsupported, "\(store.path): no tsettings table") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, blob) in [Data(Insecure.SHA1.hash(data: certificate)), subject, emptySettings, certificate].enumerated()
        {
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(stmt, Int32(i + 1), $0.baseAddress, Int32(blob.count), transient)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FirmwareError(.unsupported, "\(store.path): \(String(cString: sqlite3_errmsg(db)))")
        }
        #else
        _ = subject
        throw FirmwareError(.unsupported, "\(store.path): this host has no SQLite")
        #endif
    }

    /// The device directory's record of the anchor its guest trusts (FirmwareWire.trustAnchorFile). A new
    /// storage generation (prepared again, another edit) has another key, so the anchor is written again.
    public static let marker = FirmwareWire.trustAnchorFile

    /// Makes `certificate` an anchor in a stopped 1.x device's system volume, through a stopped edit (begin, mount,
    /// the row, commit: the 1.x FTL is written in place). False when the device already trusts it.
    nonisolated public static func trust(
        device: URL,
        certificate: Data,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws -> Bool {
        let sha1 = Insecure.SHA1.hash(data: certificate).hexString
        func storageKey() throws -> String? {
            let record = try DeviceRecord.object(Data(contentsOf: DeviceRecord.url(device)))
            guard HostRuntime.Board(rawValue: record["board"] as? String ?? "")?.soc == .s5l8900 else {
                throw FirmwareError(.unsupported, "trust anchors are written into 1.x devices only")
            }
            return (record["storage"] as? [String: Any])?["key"] as? String
        }
        // The anchor lives in the overlay, which Erase removes while the key stays: the overlay's stamp says it holds it.
        func overlayStamp() throws -> URL? {
            let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
            defer { withExtendedLifetime(owner) {} }
            return owner.paths?.overlay.appendingPathComponent(".trust-anchor")
        }
        let markerURL = device.appendingPathComponent(marker)
        if let data = try? Data(contentsOf: markerURL),
            let m = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            m["sha1"] == sha1, m["key"] == (try storageKey()),
            let stamp = try overlayStamp(), (try? String(contentsOf: stamp, encoding: .utf8)) == sha1
        {
            return false
        }
        _ = try normalizedSubject(certificate)  // a certificate this can parse, before any work
        let session = try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log)
        do {
            let point = session.image.deletingLastPathComponent().appendingPathComponent("trust-anchor-mount")
            try await VolumeMount.withMounted(session.image, at: point) { mount in
                try addAnchor(certificate, to: mount.appendingPathComponent(path))
            }
            log("anchor \(sha1) added to /\(path)")
            try await StoppedVolumeEdit.commit(device: device, id: session.id, policy: policy, log: log)
        } catch {
            try? await StoppedVolumeEdit.discard(device: device, id: session.id, policy: policy)
            throw error
        }
        if let stamp = try overlayStamp() { try N72NAND.writeDurably(Data(sha1.utf8), to: stamp) }
        let record = try JSONSerialization.data(
            withJSONObject: ["sha1": sha1, "key": try storageKey() ?? ""],
            options: [.sortedKeys]
        )
        try record.write(to: markerURL, options: .atomic)
        return true
    }
}
