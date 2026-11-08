import FirmwareSchema
import Foundation
import HostRuntime

/// The 1.x admission step (FirmwareWire.admissionRecipeSteps: n45 2 -> 3, m68 1 -> 2): a device prepared before
/// 8a54efd has its Wi-Fi known network and the PAC'd AirPort service under /private/var/preferences, where 1.0 to
/// 1.1.2 never look. A stopped edit writes them where the firmware's configd reads them, as the recipe does now
/// (N45Board.seedSystemConfiguration: root's home, or /private/var/preferences from 1.1.3), merged into the files
/// configd has written there by then.
///
/// The edit lands in the overlay, so the overlay records it (`stamp`): an edit clones the overlay and keeps it, and
/// Erase removes the overlay, so an erased device takes the step again at its next start. A storage-key marker
/// would not do: Erase keeps the key, and every edit (the proxy's trust anchor among them) changes it.
public nonisolated enum N45Migration {
    /// -2: the set's global Proxies too (cellular through the web proxy); a device stamped by the first version takes
    /// the step again (seedSystemConfiguration merges, so it only adds what is missing).
    static let stamp = ".n45-sc-prefs-2"

    /// Runs the step on a stopped 1.x device that needs it. True when it edited. The caller holds no lease.
    nonisolated public static func systemConfiguration(
        device: URL,
        policy: StorageRecordPolicy = .standalone,
        allowRaw: Bool = false,
        log: (String) -> Void = { _ in }
    ) async throws -> Bool {
        guard let step = try pending(device: device, policy: policy, allowRaw: allowRaw) else { return false }
        let session = try await StoppedVolumeEdit.begin(device: device, policy: policy, log: log)
        do {
            let point = session.image.deletingLastPathComponent().appendingPathComponent("sc-prefs-mount")
            try await VolumeMount.withMounted(session.image, at: point) { _ = try N45Board.seedSystemConfiguration($0) }
            try await StoppedVolumeEdit.commit(device: device, id: session.id, policy: policy, log: log)
        } catch {
            try? await StoppedVolumeEdit.discard(device: device, id: session.id, policy: policy)
            throw error
        }
        log("SystemConfiguration preferences written (recipe \(step))")
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
        defer { withExtendedLifetime(owner) {} }
        if let overlay = owner.paths?.overlay {
            try N72NAND.writeDurably(Data(), to: overlay.appendingPathComponent(stamp))
        }
        try N72NAND.writeDurably(
            JSONSerialization.data(withJSONObject: ["recipe": step, "step": "n45-sc-prefs"], options: [.sortedKeys]),
            to: device.appendingPathComponent(FirmwareWire.migratedRecipeFile)
        )
        return true
    }

    /// The recipe the step brings this device to, or nil: not 1.x, prepared at or past it, or already stamped.
    static func pending(device: URL, policy: StorageRecordPolicy, allowRaw: Bool = false) throws -> Int? {
        let owner = try OwnedStorageRecord.acquire(device: device, policy: policy, allowRaw: allowRaw)
        defer { withExtendedLifetime(owner) {} }
        guard let bytes = owner.bytes, let paths = owner.paths,
            let board = (try? DeviceRecord.object(bytes))?["board"] as? String,
            HostRuntime.Board(rawValue: board)?.soc == .s5l8900
        else { return nil }
        guard let version = (try? DeviceLock.read(base: paths.base))??.recipeVersion,
            let step = FirmwareWire.admissionRecipeSteps[board]?[version],
            !FileManager.default.fileExists(atPath: paths.overlay.appendingPathComponent(stamp).path)
        else { return nil }
        return step
    }
}
