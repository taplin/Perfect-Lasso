import Foundation

/// Live, runtime-mutable FileMaker host/port resolution for every
/// configured FileMaker alias — the foundation for the admin console's
/// "switch datasource" feature (`AdminConsoleDelegate.availableConfigs(for:)`/
/// `switchDatasource(name:to:)`).
///
/// `ServerConfig.filemakerHostOverrides` (the config-file-level per-alias
/// override — see that type's doc comment) only decides what each alias
/// resolves to *at startup*. This actor is seeded from that same config,
/// but its `activeProfileID` mapping can be changed afterward, live, via
/// `switchAlias(_:to:)` — e.g. pointing the primary FileMaker alias at a
/// dev/backup server's profile without editing the config file or
/// restarting the process. Every FileMaker query goes through
/// `resolve(alias:)`, so a switch takes effect on the very next query.
///
/// A "profile" here is any known FileMaker connection — the shared
/// `filemaker` block (`id: "primary"`) plus one profile per alias that
/// has its own `host` override in the config file (`id` = that alias's
/// name). Switching doesn't create new profiles at runtime, only
/// re-points an alias at one of the profiles that already exist —
/// keeping "what hosts can this server even reach" a config-file-level
/// decision (auditable, chmod-600-protected) while "which alias uses
/// which of those hosts right now" becomes a live one.
actor FileMakerConnectionRegistry {
    struct Profile: Sendable, Equatable {
        let id: String
        let label: String
        let host: String
        let port: Int
    }

    /// Fixed at construction — the set of reachable hosts is a config-file
    /// decision, not something switching grows at runtime.
    private let profiles: [String: Profile]
    /// Lowercased alias -> currently-active profile id. The only mutable
    /// state here; `switchAlias(_:to:)` is the only way it changes.
    private var activeProfileID: [String: String]

    init(config: ServerConfig) {
        var profiles: [String: Profile] = [:]
        if let host = config.filemakerHost {
            let port = config.filemakerPort ?? 80
            profiles["primary"] = Profile(id: "primary", label: "Primary (\(host):\(port))", host: host, port: port)
        }
        for (alias, override) in config.filemakerHostOverrides {
            let port = override.port ?? config.filemakerPort ?? 80
            profiles[alias] = Profile(id: alias, label: "\(alias) (\(override.host):\(port))", host: override.host, port: port)
        }
        self.profiles = profiles

        var active: [String: String] = [:]
        for alias in config.filemakerDatasourceAliases {
            let lowered = alias.lowercased()
            active[lowered] = config.filemakerHostOverrides[lowered] != nil ? lowered : "primary"
        }
        self.activeProfileID = active
    }

    /// The host/port a given alias currently resolves to. `nil` for an
    /// alias this registry doesn't know about (not a configured FileMaker
    /// alias) or whose active profile was somehow removed (can't happen
    /// via `switchAlias`, which only accepts known profile ids, but kept
    /// as a safe `nil` rather than a forced-unwrap crash).
    func resolve(alias: String) -> (host: String, port: Int)? {
        let lowered = alias.lowercased()
        guard let profileID = activeProfileID[lowered], let profile = profiles[profileID] else { return nil }
        return (profile.host, profile.port)
    }

    /// All known connection profiles, with `isActive` set for whichever
    /// one `alias` currently resolves to. Returns an empty array for an
    /// alias this registry doesn't recognize (matches
    /// `AdminConsoleDelegate.availableConfigs(for:)`'s documented
    /// "return empty to suppress the switcher" contract).
    func availableProfiles(for alias: String) -> [(id: String, label: String, isActive: Bool)] {
        let lowered = alias.lowercased()
        guard let active = activeProfileID[lowered] else { return [] }
        return profiles.values
            .sorted { $0.id < $1.id }
            .map { ($0.id, $0.label, $0.id == active) }
    }

    /// Re-points `alias` at a different, already-known profile. Returns
    /// the profile that's now active, or `nil` if either `alias` isn't a
    /// registered FileMaker alias or `profileID` doesn't name a known
    /// profile — the caller (`LassoAdminDelegate.switchDatasource`) turns
    /// a `nil` into a clean, user-facing failure message rather than a throw.
    @discardableResult
    func switchAlias(_ alias: String, to profileID: String) -> Profile? {
        let lowered = alias.lowercased()
        guard activeProfileID[lowered] != nil, let profile = profiles[profileID] else { return nil }
        activeProfileID[lowered] = profileID
        return profile
    }
}
