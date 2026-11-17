import Foundation

/// Personal build addition: adds the baked TweakStreams AioFin account to the
/// active profile when it is missing or has no Keychain token, so a reinstall
/// does not need it typed in again. Existing rows keep their library
/// selection and sync choice. Credentials come from the gitignored
/// `BakedJellyfinSecrets.generated.swift`.
///
/// Also removes rows an earlier build seeded: AioFin on the retired Hetzner
/// host, the pre-Hetzner Dubai id, and Aiometa JF, whose 18-library auto-sync
/// never finished and restarted on every launch.
enum BakedJellyfinAccounts {
    private struct Account {
        let id: String
        let displayName: String
        let url: String
        let username: String
        let password: String
    }

    private static let retiredServerIDs: Set<String> = [
        "baked-aiofin",
        "baked-aiofin-hetzner",
        "baked-aiometa",
    ]

    private static var accounts: [Account] {
        [
            Account(
                id: "baked-aiofin-dubai",
                displayName: "AioFin",
                url: BakedJellyfinSecrets.aiofinURL,
                username: BakedJellyfinSecrets.aiofinUsername,
                password: BakedJellyfinSecrets.aiofinPassword
            )
        ]
    }

    /// Removes retired rows, then logs in and stores each baked account that
    /// the active profile lacks.
    @MainActor
    static func ensureForActiveProfile() async {
        let store = JellyfinServerStore.shared
        for server in store.servers where retiredServerIDs.contains(server.id) {
            store.remove(server.id)
        }
        for account in accounts {
            guard !account.url.isEmpty, let baseURL = URL(string: account.url) else { continue }
            let existing = store.servers.first {
                normalized($0.baseURLString) == normalized(account.url)
                    && $0.username == account.username
            }
            if let existing, !JellyfinCredentialStore.token(forServerID: existing.id).isEmpty {
                continue
            }
            guard let auth = try? await JellyfinSessionManager.login(
                baseURL: baseURL,
                username: account.username,
                password: account.password
            ) else { continue }
            var config = existing ?? JellyfinServerConfig(
                id: account.id,
                displayName: account.displayName,
                baseURLString: baseURL.absoluteString,
                authKind: .login,
                username: account.username,
                syncAutomatically: false
            )
            config.authKind = .login
            config.userId = auth.userId
            JellyfinCredentialStore.save(auth.accessToken, forServerID: config.id)
            store.upsert(config)
        }
    }

    private static func normalized(_ url: String) -> String {
        url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
