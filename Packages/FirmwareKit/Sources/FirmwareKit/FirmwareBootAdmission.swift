import FirmwareSchema
import Foundation
import HostRuntime

/// Common stopped storage admission used before any host launches a helper.
/// Format-specific preparation borrows the existing stopped authority: the N72
/// recipe 1 -> 2 GPT migration (N72NAND.migrateLegacyGPT), and before it 1.x's
/// SystemConfiguration step (N45Migration), a stopped edit of its own.
public nonisolated enum FirmwareBootAdmission {
    public struct Result: Sendable {
        public let changed: Bool
        public let record: Data?
        public let paths: StorageRecordPaths?
        /// A quiet notice for the device's window (FirmwareWire.BootAdmission.notice).
        public var notice: String? = nil

        public func jsonData() throws -> Data {
            let header = try JSONEncoder().encode(FirmwareWire.BootAdmission(changed: changed, notice: notice))
            guard var output = try JSONSerialization.jsonObject(with: header) as? [String: Any] else {
                throw StorageRecordPaths.Failure.invalidRecord
            }
            output["paths"] = NSNull()
            if let paths {
                var selected = ["base": paths.base.path, "overlay": paths.overlay.path]
                if let nor = paths.writableNOR { selected["writableNOR"] = nor.path }
                if let snapshot = paths.snapshot { selected["snapshot"] = snapshot.path }
                output["paths"] = selected
            }
            return try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    nonisolated public static func admit(
        device: URL,
        policy: StorageRecordPolicy = .standalone,
        allowRaw: Bool = false
    ) async throws -> Result {
        // 1.x's step is a stopped edit, which takes its own lease, so it runs before admission's. A failure (an FTL
        // the guest didn't shut down cleanly is refused) doesn't keep the device from starting; the next start retries.
        if let record = try? DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name))) {
            try DeviceRecord.requireReadable(record)  // before any step touches storage this build may not know
        }
        var edited = false
        do {
            edited = try await N45Migration.systemConfiguration(device: device, policy: policy, allowRaw: allowRaw)
        } catch is CancellationError { throw CancellationError() } catch {
            FirmwareDiagnostics.write(Data("boot admission: 1.x SystemConfiguration step skipped: \(error)\n".utf8))
        }
        let notice = NoticeBox()
        let result = try await admit(device: device, policy: policy, allowRaw: allowRaw) { owner in
            try migrate(owner) { notice.text = $0 }
        }
        return Result(
            changed: result.changed || edited,
            record: result.record,
            paths: result.paths,
            notice: notice.text
        )
    }

    /// Set once, by the one preparation an admission runs.
    final class NoticeBox: @unchecked Sendable { var text: String? }

    static func migrate(_ owner: StoppedRecordOwner, notice: (String) -> Void = { _ in }) throws -> Bool {
        guard let bytes = owner.bytes, let paths = owner.paths,
            let record = try? DeviceRecord.object(bytes)
        else { return false }
        if let board = record["board"] as? String, HostRuntime.Board(rawValue: board)?.isKBoot == true {
            // The A4 and S5L8920 boards' format 2: an image store, written in place (K48NANDMigration).
            let imaged = try K48NANDMigration.admit(owner, notice: notice)
            guard HostRuntime.Board(rawValue: board)?.kbootPhone == true else { return imaged }
            let identity = try iPhoneIMEI(
                base: paths.base,
                marker: owner.device.appendingPathComponent(FirmwareWire.migratedRecipeFile)
            )
            return imaged || identity
        }
        if HostRuntime.Board(rawValue: record["board"] as? String ?? "")?.soc == .s5l8900 {
            // after the 1.x SystemConfiguration step (admit), whose stopped edit wrote the format 1 overlay
            return try K48NANDMigration.admit(owner, notice: notice)
        }
        guard record["board"] as? String == "n72ap" else { return false }
        // the recipe 1 -> 2 GPT pages go into the format 1 overlay, which the image migration then carries
        let gpt = try N72NAND.migrateLegacyGPT(
            base: paths.base,
            overlay: paths.overlay,
            storageKey: (record["storage"] as? [String: Any])?["key"] as? String,
            marker: owner.device.appendingPathComponent(FirmwareWire.migratedRecipeFile)
        )
        return try K48NANDMigration.admit(owner, notice: notice) || gpt
    }

    /// n90/n88 recipe 1 -> 2: the identity gains the IMEI the modem reports, and the UDID it makes
    /// (IPhoneIdentity). The read-only base keeps its identity.json; both values are pure functions of it, so
    /// the boot derives the IMEI (DeviceLock.machineOptions) and the app the UDID. The marker records the step.
    static func iPhoneIMEI(base: URL, marker: URL) throws -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: marker.path),
            let lock = try? DeviceLock.read(base: base), let version = lock.recipeVersion,
            let board = lock.board, let step = FirmwareWire.admissionRecipeSteps[board]?[version],
            let identity = (try? Data(contentsOf: base.appendingPathComponent("identity.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            identity["imei"] == nil, let upgraded = IPhoneIdentity.upgraded(identity)
        else { return false }
        try N72NAND.writeDurably(
            JSONSerialization.data(
                withJSONObject: [
                    "recipe": step, "step": "iphone-imei",
                    "imei": upgraded.imei, "udid": upgraded.udid,
                ],
                options: [.sortedKeys]
            ),
            to: marker
        )
        return true
    }

    nonisolated static func admit(
        device: URL,
        policy: StorageRecordPolicy = .standalone,
        allowRaw: Bool = false,
        prepare: @Sendable (StoppedRecordOwner) async throws -> Bool
    ) async throws -> Result {
        try Task.checkCancellation()
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy, allowRaw: allowRaw)
        guard let paths = owner.paths, let bytes = owner.bytes else {
            return Result(changed: false, record: nil, paths: nil)
        }
        try DeviceRecord.requireReadable(DeviceRecord.object(bytes))
        // Keep the shared lease live through preparation, record reread and
        // refreshed ownership validation, including cancellation/error paths.
        defer { withExtendedLifetime(owner.lease) {} }
        let changed = try await prepare(owner)
        try Task.checkCancellation()
        // Keep the stopped authority across the reread and ownership validation.
        // Publication invalidates the original owner's path snapshot.
        let current = try Data(contentsOf: DeviceRecord.url(owner.device))
        let selected = try StorageRecordPaths(bytes: current, relativeRoot: paths.relativeRoot)
        try selected.validate(policy, device: owner.device)
        return Result(changed: changed, record: current, paths: selected)
    }
}
