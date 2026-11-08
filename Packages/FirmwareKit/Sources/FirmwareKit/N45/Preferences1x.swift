// iPhone OS 1.x runs no guest agent, so Tweaks' preference keys go into the stopped device: its system volume (1.x
// keeps /private/var on it), in the Preferences of the user SpringBoard runs as (root's to 1.1.2, mobile's from 1.1.3:
// N45Board.springBoardUser), where SpringBoard and MobileSafari read them as they start. A new file takes its
// folder's owner (the stopped edit's commit), as the agent's chown does on 2.x and later.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import HostRuntime

public enum Preferences1x {
    /// The overlay's record of the keys it holds (the hash of the set ones): Erase empties the overlay, and the next
    /// start writes them again.
    static let stamp = ".preferences"

    /// Applies `changes`, each ["domain", "key", "value"] (no value: the key removed), through a stopped edit. False
    /// when the device's overlay already holds the keys they set.
    nonisolated public static func write(
        device: URL,
        changes: [[String: Any]],
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws -> Bool {
        let record = try DeviceRecord.object(Data(contentsOf: DeviceRecord.url(device)))
        guard HostRuntime.Board(rawValue: record["board"] as? String ?? "")?.soc == .s5l8900 else {
            throw FirmwareError(.unsupported, "preferences are written into stopped 1.x devices only")
        }
        let digest = try digest(changes)
        // the current overlay's stamp; the record's owner is released before the edit takes it
        func stampURL() throws -> URL? {
            let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
            defer { withExtendedLifetime(owner) {} }
            return owner.paths?.overlay.appendingPathComponent(stamp)
        }
        if let url = try stampURL(), (try? String(contentsOf: url, encoding: .utf8)) == digest { return false }
        let session = try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log)
        do {
            let point = session.image.deletingLastPathComponent().appendingPathComponent("preferences-mount")
            try await VolumeMount.withMounted(session.image, at: point) { mount in
                let dir = N45Board.springBoardUser(mount).library + "/Preferences"
                for (domain, keys) in Dictionary(grouping: changes, by: { $0["domain"] as? String ?? "" }) {
                    guard !domain.isEmpty, !domain.contains("/") else {
                        throw FirmwareError(.internal, "a preference change without a domain")
                    }
                    try SystemEdits.seedPlist(mount.appendingPathComponent("\(dir)/\(domain).plist")) { d in
                        for change in keys {
                            guard let key = change["key"] as? String else { continue }
                            if let value = change["value"] { d[key] = value } else { d.removeObject(forKey: key) }
                        }
                    }
                    log("/\(dir)/\(domain).plist: \(keys.compactMap { $0["key"] as? String }.joined(separator: ", "))")
                }
            }
            try await StoppedVolumeEdit.commit(device: device, id: session.id, policy: policy, log: log)
        } catch {
            try? await StoppedVolumeEdit.discard(device: device, id: session.id, policy: policy)
            throw error
        }
        if let url = try stampURL() { try N72NAND.writeDurably(Data(digest.utf8), to: url) }
        return true
    }

    /// The keys `changes` set, in order: the same set gives the same stamp whatever was removed with it.
    static func digest(_ changes: [[String: Any]]) throws -> String {
        let set = changes.filter { $0["value"] != nil }
            .sorted { "\($0["domain"] ?? "") \($0["key"] ?? "")" < "\($1["domain"] ?? "") \($1["key"] ?? "")" }
            .map { [$0["domain"] ?? "", $0["key"] ?? "", $0["value"] ?? ""] }
        let data = try PropertyListSerialization.data(fromPropertyList: set, format: .binary, options: 0)
        return SHA256.hash(data: data).hexString
    }
}
