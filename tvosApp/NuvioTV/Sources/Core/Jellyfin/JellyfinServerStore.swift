import Foundation

/// Configured Jellyfin servers for the active profile. Mirrors
/// `SMBServerStore`'s UserDefaults-JSON-blob pattern: small, profile-scoped,
/// notification-driven so Settings and Home can react without a shared timer.
@MainActor
final class JellyfinServerStore: ObservableObject {
    static let shared = JellyfinServerStore()

    static let changedNotification = Notification.Name("nuvio.tv.jellyfin.servers.changed")

    @Published private(set) var servers: [JellyfinServerConfig] = []

    private init() {
        servers = Self.load()
    }

    /// Re-reads from the active profile's store. Call after a profile switch.
    func reload() {
        servers = Self.load()
    }

    func server(id: String) -> JellyfinServerConfig? {
        servers.first { $0.id == id }
    }

    func upsert(_ server: JellyfinServerConfig) {
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        persist(updated)
    }

    func remove(_ serverID: String) {
        var updated = servers
        updated.removeAll { $0.id == serverID }
        persist(updated)
        JellyfinCredentialStore.remove(forServerID: serverID)
        JellyfinLibraryIndex.shared.removeAll(forServerID: serverID)
        // An interrupted sync leaves its checkpoint and listing pages behind.
        JellyfinSyncCheckpoints.remove(profileID: ProfileSettings.activeProfileID ?? "default", serverID: serverID)
    }

    private func persist(_ servers: [JellyfinServerConfig]) {
        self.servers = servers
        guard let data = try? JSONEncoder().encode(servers) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.jellyfinServers)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private static func load() -> [JellyfinServerConfig] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.jellyfinServers),
              let servers = try? JSONDecoder().decode([JellyfinServerConfig].self, from: data) else { return [] }
        return servers
    }
}

/// Profile setting that decides whether configured Jellyfin servers are offered
/// as playback sources. Off by default, so add-on streams are the only sources
/// while the Jellyfin account keeps serving Continue Watching and watch progress.
///
/// A Jellyfin server records progress by itself only for files it serves. With
/// Jellyfin sources off, the app must report progress, so turning sources off
/// also turns on Jellyfin Scrobble when Jellyfin is the Continue Watching source.
enum JellyfinStreamSourceSettings {
    static func isEnabled(in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.object(forKey: SettingsKey.jellyfinStreamSourceEnabled) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool, in store: UserDefaults = ProfileSettings.current) {
        store.set(enabled, forKey: SettingsKey.jellyfinStreamSourceEnabled)
        if !enabled { enableScrobbleIfJellyfinIsProgressSource(in: store) }
    }

    /// Applies the default once per profile: sources off, scrobble on.
    static func migrateIfNeeded(in store: UserDefaults = ProfileSettings.current) {
        guard store.object(forKey: SettingsKey.jellyfinStreamSourceEnabled) == nil else { return }
        store.set(false, forKey: SettingsKey.jellyfinStreamSourceEnabled)
        enableScrobbleIfJellyfinIsProgressSource(in: store)
    }

    private static func enableScrobbleIfJellyfinIsProgressSource(in store: UserDefaults) {
        guard TraktSettingsStore.watchProgressSource(in: store) == .jellyfin else { return }
        store.set(true, forKey: SettingsKey.jellyfinScrobbleEnabled)
    }
}
