import Foundation

/// Personal build addition: adds the baked TweakStreams Jellyfin accounts to
/// the active profile when they are missing or have no Keychain token, so a
/// reinstall does not need them typed in again. Existing rows keep their
/// library selection and sync choice. Credentials come from the gitignored
/// `BakedJellyfinSecrets.generated.swift`.
enum BakedJellyfinAccounts {
    private struct Account {
        let id: String
        let displayName: String
        let url: String
        let username: String
        let password: String
    }

    private static var accounts: [Account] {
        [
            Account(
                id: "baked-aiofin",
                displayName: "AioFin",
                url: BakedJellyfinSecrets.aiofinURL,
                username: BakedJellyfinSecrets.aiofinUsername,
                password: BakedJellyfinSecrets.aiofinPassword
            ),
            Account(
                id: "baked-aiometa",
                displayName: "Aiometa JF",
                url: BakedJellyfinSecrets.aiometaURL,
                username: BakedJellyfinSecrets.aiometaUsername,
                password: BakedJellyfinSecrets.aiometaPassword
            )
        ]
    }

    /// Logs in and stores each baked account that the active profile lacks.
    @MainActor
    static func ensureForActiveProfile() async {
        let store = JellyfinServerStore.shared
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
