import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.vantine.VMDeck", category: "HostStore")

@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []

    /// One VMStore per host, created on first use. Not observed: it's a cache
    /// that views read from during body evaluation.
    @ObservationIgnored private var vmStores: [Host.ID: VMStore] = [:]
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = HostStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            do {
                hosts = try JSONDecoder().decode([Host].self, from: data)
            } catch {
                log.error("Couldn't read \(fileURL.path, privacy: .public): \(error)")
            }
        } else if FileManager.default.isExecutableFile(atPath: Host.defaultVMRunPath) {
            // First launch on a Mac with Fusion: start with this Mac listed.
            hosts = [Host(name: "This Mac", kind: .local)]
            save()
        }
    }

    static var defaultFileURL: URL {
        #if DEBUG
        // `--args -VMDeckHostsFile /path/hosts.json`: run against fixture hosts
        // without touching the real list.
        if let path = UserDefaults.standard.string(forKey: "VMDeckHostsFile") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VMDeck/hosts.json")
    }

    func host(_ id: Host.ID) -> Host? {
        hosts.first { $0.id == id }
    }

    /// The host's store if it has been created, without creating one.
    func existingStore(for id: Host.ID) -> VMStore? {
        vmStores[id]
    }

    func store(for host: Host) -> VMStore {
        if let existing = vmStores[host.id], existing.host == host {
            return existing
        }
        let store = VMStore(host: host)
        vmStores[host.id] = store
        return store
    }

    func add(_ host: Host) {
        hosts.append(host)
        save()
    }

    func update(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        vmStores[host.id] = nil
        save()
    }

    func remove(_ id: Host.ID) {
        hosts.removeAll { $0.id == id }
        vmStores[id] = nil
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(hosts).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Couldn't save hosts: \(error)")
        }
    }
}
